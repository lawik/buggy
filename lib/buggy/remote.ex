defmodule Buggy.Remote do
  @moduledoc """
  Remote control over Erlang distribution, used by the AtomVM badge.

  The badge sends to `{Buggy.Remote, :"buggy@<ip>"}` (see
  `Buggy.Distribution`). Every message carries `from`, the pid to reply to:

    * `{:hello, from}`: sent every ~500 ms while idle. Reply:
      `{:buggy, robot_state}`, the `BB.Robot.Runtime.state/1` atom, or
      `:unavailable` when the robot isn't running.

    * `{:drive, from, throttle, steering}`: every 100 ms while a key is held,
      then once with both at `0.0` on release. Donkey Car convention,
      `-1.0..1.0` (see `Buggy.Drive`). Only applied while the robot is
      `:idle`: armed, with no command running. Each throttle lasts
      300 ms, so the car stops on its own if the badge goes away. Reply:
      `{:buggy, robot_state}`.

    * `{:command, from, :arm | :disarm}`. Reply:
      `{:buggy_command, name, text}`, where text is `"ok"` or a short reason.

    * `{:frame, from, width, height}`: the newest camera frame, scaled to
      `width` × `height`. Reply: RGBA8888 stripes of whole rows, see
      `Buggy.Remote.Frame`. Until the camera has produced a frame there's no
      reply; the request is answered when the first one arrives.

  Frames come from the camera sensor's `BB.Message.Sensor.Image` messages.
  The subscription only lasts while frames are being asked for, because the
  camera only decodes frames while something subscribes to its images.
  """
  use GenServer

  require Logger

  alias Buggy.Drive
  alias Buggy.Remote.Frame

  @robot Buggy.Robot
  @camera_path [:sensor, :base_link, :camera]
  @throttle_ms 300
  @max_frame_side 640
  # Stop watching the camera after this long without a frame request.
  @frame_idle_ms 10_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       robot: Keyword.get(opts, :robot, @robot),
       camera_path: Keyword.get(opts, :camera_path, @camera_path),
       image: nil,
       last_frame_request: nil,
       idle_timer: nil,
       frame_worker: nil,
       pending_frame: nil,
       last_drive_error: nil
     }}
  end

  @impl GenServer
  def handle_info({:hello, from}, state) when is_pid(from) do
    send(from, {:buggy, robot_state(state.robot)})
    {:noreply, state}
  end

  def handle_info({:drive, from, throttle, steering}, state)
      when is_pid(from) and is_number(throttle) and is_number(steering) do
    robot_state = robot_state(state.robot)

    state =
      if robot_state == :idle do
        drive(state, throttle, steering)
      else
        state
      end

    send(from, {:buggy, robot_state})
    {:noreply, state}
  end

  def handle_info({:command, from, name}, state)
      when is_pid(from) and name in [:arm, :disarm] do
    robot = state.robot
    # Arming can take a moment, and drive messages shouldn't wait for it.
    Task.start(fn -> send(from, {:buggy_command, name, run_command(robot, name)}) end)
    {:noreply, state}
  end

  def handle_info({:frame, from, width, height}, state)
      when is_pid(from) and is_integer(width) and width in 1..@max_frame_side and
             is_integer(height) and height in 1..@max_frame_side do
    state =
      %{state | last_frame_request: System.monotonic_time(:millisecond)}
      |> watch_camera()
      |> request_frame({from, width, height})

    {:noreply, state}
  end

  def handle_info(
        {:bb, path, %BB.Message{payload: %BB.Message.Sensor.Image{} = image}},
        %{camera_path: path} = state
      ) do
    {:noreply, serve_pending(%{state | image: image})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{frame_worker: ref} = state) do
    if reason != :normal, do: Logger.warning("Sending a frame failed: #{inspect(reason)}")
    {:noreply, serve_pending(%{state | frame_worker: nil})}
  end

  def handle_info(:frame_idle_check, state) do
    idle = System.monotonic_time(:millisecond) - state.last_frame_request

    if idle >= @frame_idle_ms do
      unsubscribe(state)
      {:noreply, %{state | idle_timer: nil, image: nil, pending_frame: nil}}
    else
      timer = Process.send_after(self(), :frame_idle_check, @frame_idle_ms - idle)
      {:noreply, %{state | idle_timer: timer}}
    end
  end

  def handle_info(message, state) do
    Logger.debug("Buggy.Remote ignored #{inspect(message, limit: 5)}")
    {:noreply, state}
  end

  # The robot's state lives in ETS tables that don't exist while it isn't
  # running (on the host without SIMULATE=1, or mid-restart).
  defp robot_state(robot) do
    BB.Robot.Runtime.state(robot)
  rescue
    ArgumentError -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  defp drive(state, throttle, steering) do
    result =
      with {:ok, _} <- Drive.steer(steering, state.robot) do
        Drive.throttle(throttle, @throttle_ms, state.robot)
      end

    # Drive messages come at 10 Hz, so only log when the error changes.
    case result do
      {:ok, _} ->
        %{state | last_drive_error: nil}

      {:error, reason} when reason == state.last_drive_error ->
        state

      {:error, reason} ->
        Logger.warning("Badge drive failed: #{inspect(reason)}")
        %{state | last_drive_error: reason}
    end
  end

  defp run_command(robot, name) do
    with {:ok, command} <- apply(robot, name, []),
         {:ok, _} <- BB.Command.await(command, 10_000) do
      "ok"
    else
      {:ok, _, _} -> "ok"
      {:error, reason} -> describe(reason)
    end
  end

  defp describe(reason) do
    text = if is_exception(reason), do: Exception.message(reason), else: inspect(reason)
    String.slice(text, 0, 80)
  end

  # (Re)subscribe whenever we aren't, which also covers the robot having
  # restarted and taken its PubSub registry, and our subscription, with it.
  defp watch_camera(state) do
    subscribed? =
      state.robot
      |> BB.PubSub.subscribers(state.camera_path)
      |> Enum.any?(fn {pid, _types} -> pid == self() end)

    unless subscribed? do
      BB.PubSub.subscribe(state.robot, state.camera_path,
        message_types: [BB.Message.Sensor.Image]
      )
    end

    if state.idle_timer do
      state
    else
      %{state | idle_timer: Process.send_after(self(), :frame_idle_check, @frame_idle_ms)}
    end
  rescue
    # The robot isn't running, so there's no registry to subscribe to.
    ArgumentError -> state
  end

  defp unsubscribe(state) do
    BB.PubSub.unsubscribe(state.robot, state.camera_path)
  rescue
    ArgumentError -> :ok
  end

  # One frame at a time, converted off this process so drive messages don't
  # queue behind it. A request that comes in meanwhile replaces any waiting
  # one, so the badge always gets the newest frame.
  defp request_frame(%{image: nil} = state, request), do: %{state | pending_frame: request}

  defp request_frame(%{frame_worker: nil, image: image} = state, {from, width, height}) do
    {_pid, ref} = spawn_monitor(fn -> Frame.send_frame(from, image, width, height) end)
    %{state | frame_worker: ref}
  end

  defp request_frame(state, request), do: %{state | pending_frame: request}

  defp serve_pending(%{pending_frame: nil} = state), do: state

  defp serve_pending(%{pending_frame: request} = state),
    do: request_frame(%{state | pending_frame: nil}, request)
end
