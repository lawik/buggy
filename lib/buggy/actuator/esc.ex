defmodule Buggy.Actuator.ESC do
  @moduledoc """
  An RC car ESC (electronic speed controller) on a PCA9685 channel.

  An ESC reads the same 50 Hz pulse train as a servo, but as throttle:
  `neutral_pulse` is stopped, `forward_pulse` is full forward and
  `reverse_pulse` full reverse. `Command.Velocity` is mapped linearly onto
  that range, taking the joint's velocity limit as full throttle, and the
  magnitude is capped at `max_throttle` whoever sent the command. Point
  `max_throttle` at a parameter to tune it live; lowering it below the
  current throttle takes effect immediately.

  The pulses can be parameters too, to calibrate the ESC live. A change is
  written at once: the current throttle with the new pulses while armed, or
  the new neutral while disarmed, so neutral can be trimmed by ear until the
  ESC stops humming and arms.

  Safety:

    * Neutral is sent on start-up, which an ESC needs to see before it arms.
    * Every velocity command times out back to neutral, after its `duration`
      or after `watchdog_ms` if it has none, so a caller that goes away can't
      leave the motor running.
    * `Command.Stop` and `disarm/1` both send neutral. `disarm/1` asks the
      running actuator for its current neutral, in case it has been
      recalibrated since start-up, and uses the start-up one if it doesn't
      answer promptly.
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

  # How long disarm waits for the running actuator's current neutral.
  @neutral_query_ms 100

  @impl BB.Actuator
  def disarm(opts) do
    write(opts[:robot], opts[:controller], opts[:channel], current_neutral(opts))
  end

  # The registration holds the neutral from start-up, and BB.Safety can't
  # update it, so a recalibrated neutral is asked for. Disarm can't rely on the
  # actuator's process, though, so anything but a prompt answer falls back.
  defp current_neutral(opts) do
    case BBProcess.call(opts[:robot], opts[:name], :neutral_pulse, @neutral_query_ms) do
      pulse when is_integer(pulse) -> pulse
      _other -> opts[:neutral_pulse]
    end
  catch
    :exit, _reason -> opts[:neutral_pulse]
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
      throttle: 0.0,
      watchdog: nil
    }

    with :ok <- validate_velocity_limit(state),
         :ok <- write_neutral(state) do
      BB.Safety.register(__MODULE__,
        robot: bb.robot,
        path: bb.path,
        opts: [
          robot: bb.robot,
          name: List.last(bb.path),
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

  # Parameter changes. New pulses (calibration) are written straight away; a
  # `max_throttle` below what the motor is doing now clamps it straight away.
  @impl BB.Actuator
  def handle_options(new_opts, state) do
    old = state

    state = %{
      state
      | neutral_pulse: Keyword.fetch!(new_opts, :neutral_pulse),
        forward_pulse: Keyword.fetch!(new_opts, :forward_pulse),
        reverse_pulse: Keyword.fetch!(new_opts, :reverse_pulse),
        max_throttle: Keyword.fetch!(new_opts, :max_throttle),
        watchdog_ms: Keyword.fetch!(new_opts, :watchdog_ms),
        velocity_limit: Keyword.fetch!(new_opts, :motor_profile).motor_velocity_limit
    }

    cond do
      pulses(state) != pulses(old) -> rewrite(state)
      abs(state.throttle) > state.max_throttle -> rewrite(state)
      true -> {:ok, state}
    end
  end

  @impl BB.Actuator
  def handle_call(:neutral_pulse, _from, state), do: {:reply, state.neutral_pulse, state}

  @impl BB.Actuator
  def handle_command(%Message{payload: %Command.Velocity{} = cmd}, state) do
    case set_throttle(state, cmd.velocity / state.velocity_limit) do
      {:ok, state} -> {:noreply, arm_watchdog(state, cmd.duration || state.watchdog_ms)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_command(%Message{payload: %Command.Stop{}}, state) do
    case set_throttle(state, 0.0) do
      {:ok, state} -> {:noreply, cancel_watchdog(state)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl BB.Actuator
  def handle_info({:watchdog, ref}, %{watchdog: {ref, _timer}} = state) do
    state =
      case set_throttle(state, 0.0) do
        {:ok, state} -> state
        {:error, _reason} -> state
      end

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

  defp set_throttle(state, requested) do
    throttle = requested |> max(-state.max_throttle) |> min(state.max_throttle)
    pulse = throttle_to_pulse(throttle, state)

    with :ok <- write(state, pulse) do
      Logger.debug("ESC throttle #{Float.round(throttle * 1.0, 3)} -> #{pulse}µs")
      {:ok, %{state | throttle: throttle}}
    end
  end

  defp pulses(state), do: {state.neutral_pulse, state.forward_pulse, state.reverse_pulse}

  # The current throttle again, with the current pulses and cap. Disarmed, the
  # motor should be at neutral whatever throttle was last asked for.
  defp rewrite(state) do
    throttle = if BB.Safety.armed?(state.bb.robot), do: state.throttle, else: 0.0

    case set_throttle(state, throttle) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

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
