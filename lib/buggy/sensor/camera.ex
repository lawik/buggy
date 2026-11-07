defmodule Buggy.Sensor.Camera do
  @moduledoc """
  The Raspberry Pi camera as a BB sensor, streaming through Membrane.

  `rpicam-vid` encodes H.264 in hardware, and `Buggy.Camera.Pipeline` sends it
  over WebRTC to every viewer that attaches through
  `BB.LiveView.VideoSource`, which is how the dashboard plays it. The sensor
  registers as a video source under `[:sensor | path]`, e.g.
  `[:sensor, :base_link, :camera]`.

  Its settings (resolution, sensor mode, bitrate, exposure...) are options,
  normally pointed at the robot's `video.*` parameters, so they can be
  changed live and are saved with the other parameters. See
  `Buggy.Camera.Settings`. `rpicam-vid` takes them at start only, so a change
  restarts it, a second after the last change so a dragged slider restarts
  it once. Viewers are told the stream ended and attach again.

  Raw frames, published as 160x120 rgb8 `BB.Message.Sensor.Image` under the
  same path, come from a branch that decodes the stream in hardware
  (`Membrane.V4L2.H264.Decoder`, which also converts and scales them). It
  only runs while some process subscribes to this path (or an ancestor)
  asking for `BB.Message.Sensor.Image` by type, the way `Buggy.Remote` does.
  Catch-all subscribers such as the dashboard and BB's runtime don't start
  it.

  Where there's no `rpicam-vid` (on the host) it streams ffmpeg's test
  pattern instead, if ffmpeg is installed.

  libcamera gives a camera to one process at a time, so nothing else can run
  `rpicam-*` against it while this sensor is up.
  """
  use BB.Sensor,
    options_schema: [
      resolution: [type: :string, default: "640x480", doc: "Video size, WIDTHxHEIGHT"],
      sensor_mode: [
        type: :string,
        default: "auto",
        doc: ~s(Sensor readout mode, WIDTHxHEIGHT, or "auto")
      ],
      framerate: [type: :pos_integer, default: 30, doc: "Frames per second"],
      bitrate_kbps: [type: :pos_integer, default: 1500, doc: "H.264 bitrate, kbit/s"],
      keyframe_interval: [
        type: {:or, [:float, :integer]},
        default: 1.0,
        doc: "Seconds between keyframes"
      ],
      exposure: [type: :string, default: "normal", doc: "normal, sport, short or long"],
      ev: [type: {:or, [:float, :integer]}, default: 0.0, doc: "Exposure compensation"],
      sharpness: [type: {:or, [:float, :integer]}, default: 1.0, doc: "Sharpening, 1.0 normal"],
      denoise: [type: :string, default: "auto", doc: "auto, off, cdn_off, cdn_fast or cdn_hq"],
      rotate_180: [type: :boolean, default: false, doc: "Camera mounted upside down"],
      camera: [
        type: :non_neg_integer,
        default: 0,
        doc: "Camera index, as listed by `rpicam-hello --list-cameras`"
      ]
    ]

  require Logger

  alias BB.LiveView.VideoSource
  alias BB.Message.Sensor.Image
  alias Buggy.Camera.{Pipeline, Settings}

  @restart_ms 5_000
  @frames_check_ms 1_000
  # Wait this long after a settings change for more before restarting, and
  # this long after stopping rpicam-vid for libcamera to let the camera go.
  @settle_ms 1_000
  @release_ms 750
  # Size of the published Images: the badge's view at 1:1.
  @frame_width 160
  @frame_height 120

  @impl BB.Sensor
  def init(opts) do
    # The pipeline is linked, so its exit arrives as a message and the
    # sensor can restart it instead of going down with it.
    Process.flag(:trap_exit, true)
    bb = Keyword.fetch!(opts, :bb)
    settings = settings(opts, %Settings{})

    state = %{
      bb: bb,
      topic: [:sensor | bb.path],
      settings: settings,
      supervisor: nil,
      pipeline: nil,
      viewers: %{},
      frames?: false,
      apply_timer: nil
    }

    {:ok, _} = VideoSource.register(bb.robot, state.topic, Settings.metadata(settings))
    Process.send_after(self(), :check_frames, @frames_check_ms)
    {:ok, state, {:continue, :start}}
  end

  @impl BB.Sensor
  def handle_continue(:start, state), do: {:noreply, start_pipeline(state)}

  @impl BB.Sensor
  def handle_options(opts, state) do
    settings = settings(opts, state.settings)

    if settings == state.settings do
      {:ok, state}
    else
      if state.apply_timer, do: Process.cancel_timer(state.apply_timer)
      timer = Process.send_after(self(), :apply_settings, @settle_ms)
      {:ok, %{state | settings: settings, apply_timer: timer}}
    end
  end

  @impl BB.Sensor
  def handle_call({VideoSource, :attach, _signaling}, _from, %{pipeline: nil} = state) do
    {:reply, {:error, :no_camera}, state}
  end

  def handle_call({VideoSource, :attach, signaling}, {pid, _tag}, state) do
    id = make_ref()
    send(state.pipeline, {:add_viewer, id, signaling})
    viewer = %{pid: pid, monitor: Process.monitor(pid), signaling: signaling}
    {:reply, :ok, put_in(state.viewers[id], viewer)}
  end

  def handle_call({VideoSource, :detach, signaling}, _from, state) do
    ids = for {id, %{signaling: ^signaling}} <- state.viewers, do: id
    {:reply, :ok, Enum.reduce(ids, state, &remove_viewer(&2, &1))}
  end

  @impl BB.Sensor
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    ids = for {id, %{monitor: ^ref}} <- state.viewers, do: id
    {:noreply, Enum.reduce(ids, state, &remove_viewer(&2, &1))}
  end

  def handle_info({Pipeline, :viewer_down, id}, state) do
    case Map.pop(state.viewers, id) do
      {nil, _} ->
        {:noreply, state}

      {viewer, viewers} ->
        Process.demonitor(viewer.monitor, [:flush])
        send(viewer.pid, {VideoSource, :ended, viewer.signaling})
        {:noreply, %{state | viewers: viewers}}
    end
  end

  # The next check starts it again if it's still wanted.
  def handle_info({Pipeline, :frames_down}, state), do: {:noreply, %{state | frames?: false}}

  def handle_info({:EXIT, supervisor, reason}, %{supervisor: supervisor} = state) do
    Logger.warning(
      "Camera pipeline stopped (#{inspect(reason)}), restarting in #{@restart_ms} ms"
    )

    state = end_viewers(state)
    Process.send_after(self(), :restart, @restart_ms)
    {:noreply, %{state | supervisor: nil, pipeline: nil, frames?: false}}
  end

  def handle_info(:apply_settings, state) do
    Logger.info("Camera settings changed, restarting rpicam-vid: #{inspect(state.settings)}")
    VideoSource.update(state.bb.robot, state.topic, Settings.metadata(state.settings))
    Process.send_after(self(), :restart, @release_ms)
    {:noreply, stop_pipeline(%{state | apply_timer: nil})}
  end

  def handle_info(:restart, state), do: {:noreply, start_pipeline(state)}

  def handle_info(:check_frames, state) do
    Process.send_after(self(), :check_frames, @frames_check_ms)
    wanted? = state.pipeline != nil and images_wanted?(state)

    cond do
      wanted? and not state.frames? ->
        send(state.pipeline, :start_frames)
        {:noreply, %{state | frames?: true}}

      state.frames? and not wanted? ->
        if state.pipeline, do: send(state.pipeline, :stop_frames)
        {:noreply, %{state | frames?: false}}

      true ->
        {:noreply, state}
    end
  end

  # Other exits, e.g. from processes linked by libraries, or a pipeline
  # stopped on purpose: nothing to do.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl BB.Sensor
  def terminate(_reason, %{pipeline: pipeline}) when is_pid(pipeline) do
    Membrane.Pipeline.terminate(pipeline, timeout: 5_000)
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp settings(opts, current) do
    {settings, warnings} = Settings.from_options(opts, current)
    Enum.each(warnings, &Logger.warning("Camera setting ignored: #{&1}"))
    settings
  end

  defp start_pipeline(%{pipeline: pipeline} = state) when is_pid(pipeline), do: state

  defp start_pipeline(state) do
    case source(state.settings) do
      nil ->
        Logger.warning("No rpicam-vid or ffmpeg, so #{inspect(state.topic)} has no video")
        state

      {executable, args, frames?} ->
        {:ok, supervisor, pipeline} =
          Membrane.Pipeline.start_link(Pipeline,
            owner: self(),
            executable: executable,
            args: args,
            env: [{"LIBCAMERA_LOG_LEVELS", "*:ERROR"}],
            framerate: state.settings.framerate,
            frames: if(frames?, do: frames_config(state))
          )

        %{state | supervisor: supervisor, pipeline: pipeline}
    end
  end

  # Forgetting the supervisor first makes its exit look like any other, so
  # the crash handler doesn't schedule a restart of its own.
  defp stop_pipeline(%{pipeline: nil} = state), do: state

  defp stop_pipeline(state) do
    state = end_viewers(state)
    pipeline = state.pipeline
    state = %{state | supervisor: nil, pipeline: nil, frames?: false}

    try do
      Membrane.Pipeline.terminate(pipeline, timeout: 5_000)
    catch
      :exit, _ -> :ok
    end

    state
  end

  defp end_viewers(state) do
    for {_id, viewer} <- state.viewers do
      Process.demonitor(viewer.monitor, [:flush])
      send(viewer.pid, {VideoSource, :ended, viewer.signaling})
    end

    %{state | viewers: %{}}
  end

  # Raw frames need the Pi's hardware decoder, so only the camera has them.
  defp source(settings) do
    cond do
      rpicam = System.find_executable("rpicam-vid") ->
        {rpicam, Settings.rpicam_args(settings), true}

      ffmpeg = System.find_executable("ffmpeg") ->
        {ffmpeg, Settings.ffmpeg_args(settings), false}

      true ->
        nil
    end
  end

  # bcm2835-codec's decoder is always /dev/video10; naming it saves opening
  # the camera's nodes to look for it.
  defp frames_config(state) do
    %{
      device: "/dev/video10",
      width: @frame_width,
      height: @frame_height,
      robot: state.bb.robot,
      topic: state.topic,
      frame_id: List.last(state.bb.path)
    }
  end

  defp remove_viewer(state, id) do
    case Map.pop(state.viewers, id) do
      {nil, _} ->
        state

      {viewer, viewers} ->
        Process.demonitor(viewer.monitor, [:flush])
        if state.pipeline, do: send(state.pipeline, {:remove_viewer, id})
        %{state | viewers: viewers}
    end
  end

  # Only subscribers that ask for images by type count: BB's runtime and the
  # dashboard take every sensor message, and decoding for them would be
  # wasted.
  defp images_wanted?(state) do
    robot = state.bb.robot

    Enum.any?(0..length(state.topic), fn depth ->
      robot
      |> BB.PubSub.subscribers(Enum.take(state.topic, depth))
      |> Enum.any?(fn {_pid, types} -> Image in types end)
    end)
  end
end
