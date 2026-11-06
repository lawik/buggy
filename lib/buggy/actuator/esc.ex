defmodule Buggy.Actuator.ESC do
  @moduledoc """
  An RC car ESC (electronic speed controller) on a PCA9685 channel.

  An ESC reads the same 50 Hz pulse train as a servo, but as throttle:
  `neutral_pulse` is stopped, `forward_pulse` is full forward and
  `reverse_pulse` full reverse. `Command.Velocity` is mapped linearly onto
  that range, taking the joint's velocity limit as full throttle, and the
  magnitude is capped at `max_throttle` whoever sent the command.

  Safety:

    * Neutral is sent on start-up, which an ESC needs to see before it arms.
    * Every velocity command times out back to neutral, after its `duration`
      or after `watchdog_ms` if it has none, so a caller that goes away can't
      leave the motor running.
    * `Command.Stop` and `disarm/1` both send neutral.
  """
  use BB.Actuator,
    options_schema: [
      channel: [type: {:in, 0..15}, required: true, doc: "PCA9685 channel of the ESC signal lead"],
      controller: [type: :atom, required: true, doc: "Name of the PCA9685 controller"],
      neutral_pulse: [type: :pos_integer, default: 1500, doc: "Pulse width (µs) for stopped"],
      forward_pulse: [type: :pos_integer, default: 2000, doc: "Pulse width (µs) at full forward"],
      reverse_pulse: [type: :pos_integer, default: 1000, doc: "Pulse width (µs) at full reverse"],
      max_throttle: [type: :float, default: 0.3, doc: "Cap on the throttle magnitude (0.0-1.0)"],
      watchdog_ms: [
        type: :pos_integer,
        default: 500,
        doc: "How long a velocity command without a duration runs before returning to neutral"
      ]
    ]

  require Logger

  alias BB.Message
  alias BB.Message.Actuator.Command
  alias BB.Process, as: BBProcess

  @impl BB.Actuator
  def disarm(opts) do
    write(opts[:robot], opts[:controller], opts[:channel], opts[:neutral_pulse])
  end

  @impl BB.Actuator
  def init(opts) do
    bb = Keyword.fetch!(opts, :bb)

    state = %{
      bb: bb,
      channel: Keyword.fetch!(opts, :channel),
      controller: Keyword.fetch!(opts, :controller),
      neutral_pulse: Keyword.fetch!(opts, :neutral_pulse),
      forward_pulse: Keyword.fetch!(opts, :forward_pulse),
      reverse_pulse: Keyword.fetch!(opts, :reverse_pulse),
      max_throttle: Keyword.fetch!(opts, :max_throttle),
      watchdog_ms: Keyword.fetch!(opts, :watchdog_ms),
      velocity_limit: Keyword.fetch!(opts, :motor_profile).motor_velocity_limit,
      watchdog: nil
    }

    with :ok <- validate_velocity_limit(state),
         :ok <- write_neutral(state) do
      BB.Safety.register(__MODULE__,
        robot: bb.robot,
        path: bb.path,
        opts: [
          robot: bb.robot,
          controller: state.controller,
          channel: state.channel,
          neutral_pulse: state.neutral_pulse
        ]
      )

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl BB.Actuator
  def command_payloads(_opts), do: [Command.Velocity, Command.Stop]

  @impl BB.Actuator
  def handle_command(%Message{payload: %Command.Velocity{} = cmd}, state) do
    throttle = clamp(cmd.velocity / state.velocity_limit, state.max_throttle)
    pulse = throttle_to_pulse(throttle, state)

    case write(state, pulse) do
      :ok ->
        Logger.debug("ESC throttle #{Float.round(throttle, 3)} -> #{pulse}µs")
        {:noreply, arm_watchdog(state, cmd.duration || state.watchdog_ms)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_command(%Message{payload: %Command.Stop{}}, state) do
    case write_neutral(state) do
      :ok -> {:noreply, cancel_watchdog(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl BB.Actuator
  def handle_info({:watchdog, ref}, %{watchdog: {ref, _timer}} = state) do
    _ = write_neutral(state)
    {:noreply, %{state | watchdog: nil}}
  end

  # A timer superseded by a later command.
  def handle_info({:watchdog, _ref}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  # Throttle in -1.0..1.0 to a pulse width, with forward and reverse scaled
  # separately since they needn't be symmetric about neutral.
  def throttle_to_pulse(throttle, state) when throttle >= 0,
    do: round(state.neutral_pulse + throttle * (state.forward_pulse - state.neutral_pulse))

  def throttle_to_pulse(throttle, state),
    do: round(state.neutral_pulse + throttle * (state.neutral_pulse - state.reverse_pulse))

  defp clamp(value, limit), do: value |> max(-limit) |> min(limit)

  defp arm_watchdog(state, timeout) do
    state = cancel_watchdog(state)
    ref = make_ref()
    timer = Process.send_after(self(), {:watchdog, ref}, timeout)
    %{state | watchdog: {ref, timer}}
  end

  defp cancel_watchdog(%{watchdog: nil} = state), do: state

  defp cancel_watchdog(%{watchdog: {_ref, timer}} = state) do
    Process.cancel_timer(timer)
    %{state | watchdog: nil}
  end

  defp validate_velocity_limit(%{velocity_limit: limit}) when is_number(limit) and limit > 0,
    do: :ok

  defp validate_velocity_limit(state) do
    {:error,
     "ESC #{inspect(List.last(state.bb.path))} needs a positive velocity limit on its joint " <>
       "(used as full throttle)"}
  end

  defp write_neutral(state), do: write(state, state.neutral_pulse)

  defp write(state, pulse), do: write(state.bb.robot, state.controller, state.channel, pulse)

  defp write(robot, controller, channel, pulse) do
    case BBProcess.call(robot, controller, {:pulse_width, channel, pulse}) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
