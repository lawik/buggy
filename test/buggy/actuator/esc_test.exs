defmodule Buggy.Actuator.ESCTest do
  use ExUnit.Case, async: false

  # Records every pulse width the ESC writes, standing in for the PCA9685.
  defmodule StubPWM do
    use BB.Controller

    @impl BB.Controller
    def init(_opts), do: {:ok, %{}}

    @impl BB.Controller
    def handle_call({:pulse_width, channel, us}, _from, state) do
      if pid = Process.whereis(:esc_test_listener), do: send(pid, {:pulse, channel, us})
      {:reply, :ok, state}
    end
  end

  # One continuous joint driven by the ESC. 360°/s is full throttle, so a
  # velocity of `t * 2π` rad/s asks for throttle `t`.
  defmodule Robot do
    use BB

    topology do
      link :base do
        joint :drive do
          type(:continuous)

          limit do
            effort(~u(1 newton_meter))
            velocity(~u(360 degree_per_second))
          end

          actuator(
            :esc,
            {Buggy.Actuator.ESC,
             channel: 0,
             controller: :pwm,
             neutral_pulse: param([:calibration, :neutral]),
             forward_pulse: param([:calibration, :forward]),
             reverse_pulse: param([:calibration, :reverse]),
             max_throttle: param([:limits, :max_throttle]),
             watchdog_ms: 100}
          )

          link :wheel do
          end
        end
      end
    end

    controllers do
      controller(:pwm, Buggy.Actuator.ESCTest.StubPWM)
    end

    parameters do
      group :limits do
        param(:max_throttle, type: :float, default: 0.3, min: 0.0, max: 1.0)
      end

      group :calibration do
        param(:neutral, type: :integer, default: 1500, min: 1300, max: 1700)
        param(:forward, type: :integer, default: 2000, min: 500, max: 2500)
        param(:reverse, type: :integer, default: 1000, min: 500, max: 2500)
      end
    end
  end

  @full 2 * :math.pi()

  setup do
    Process.register(self(), :esc_test_listener)
    start_supervised!(Robot)
    # Neutral on start-up, before anything is armed.
    assert_receive {:pulse, 0, 1500}
    :ok = BB.Safety.arm(Robot)
    on_exit(fn -> BB.Safety.disarm(Robot) end)
    :ok
  end

  test "maps velocity onto the pulse range, capped at max_throttle" do
    :ok = BB.Actuator.set_velocity(Robot, :esc, 0.2 * @full, delivery: :pubsub, duration: 1000)
    assert_receive {:pulse, 0, 1600}

    :ok = BB.Actuator.set_velocity(Robot, :esc, -0.2 * @full, delivery: :pubsub, duration: 1000)
    assert_receive {:pulse, 0, 1400}

    # 1.0 requested, 0.3 allowed
    :ok = BB.Actuator.set_velocity(Robot, :esc, 1.0 * @full, delivery: :pubsub, duration: 1000)
    assert_receive {:pulse, 0, 1650}
  end

  test "raising max_throttle at runtime allows more on the next command" do
    :ok = BB.Parameter.set(Robot, [:limits, :max_throttle], 0.8)
    :ok = BB.Actuator.set_velocity(Robot, :esc, 1.0 * @full, delivery: :pubsub, duration: 1000)
    assert_receive {:pulse, 0, 1900}
  end

  test "lowering max_throttle below the current throttle clamps it immediately" do
    :ok = BB.Actuator.set_velocity(Robot, :esc, 0.3 * @full, delivery: :pubsub, duration: 5000)
    assert_receive {:pulse, 0, 1650}

    :ok = BB.Parameter.set(Robot, [:limits, :max_throttle], 0.1)
    assert_receive {:pulse, 0, 1550}
  end

  test "returns to neutral after the duration, or the watchdog without one" do
    :ok = BB.Actuator.set_velocity(Robot, :esc, 0.2 * @full, delivery: :pubsub, duration: 50)
    assert_receive {:pulse, 0, 1600}
    assert_receive {:pulse, 0, 1500}, 500

    :ok = BB.Actuator.set_velocity(Robot, :esc, 0.2 * @full, delivery: :pubsub)
    assert_receive {:pulse, 0, 1600}
    assert_receive {:pulse, 0, 1500}, 500
  end

  test "stop and disarm both send neutral" do
    :ok = BB.Actuator.set_velocity(Robot, :esc, 0.2 * @full, delivery: :pubsub, duration: 5000)
    assert_receive {:pulse, 0, 1600}
    :ok = BB.Actuator.stop(Robot, :esc, delivery: :pubsub)
    assert_receive {:pulse, 0, 1500}

    :ok = BB.Actuator.set_velocity(Robot, :esc, 0.2 * @full, delivery: :pubsub, duration: 5000)
    assert_receive {:pulse, 0, 1600}
    :ok = BB.Safety.disarm(Robot)
    assert_receive {:pulse, 0, 1500}
  end

  test "a new neutral is written straight away while disarmed, and disarm uses it" do
    :ok = BB.Safety.disarm(Robot)
    assert_receive {:pulse, 0, 1500}

    :ok = BB.Parameter.set(Robot, [:calibration, :neutral], 1530)
    assert_receive {:pulse, 0, 1530}

    :ok = BB.Safety.arm(Robot)
    :ok = BB.Safety.disarm(Robot)
    assert_receive {:pulse, 0, 1530}
    refute_receive {:pulse, 0, 1500}
  end

  test "new pulses while driving rewrite the current throttle" do
    :ok = BB.Actuator.set_velocity(Robot, :esc, 0.2 * @full, delivery: :pubsub, duration: 5000)
    assert_receive {:pulse, 0, 1600}

    :ok = BB.Parameter.set(Robot, [:calibration, :forward], 2500)
    assert_receive {:pulse, 0, 1700}

    :ok = BB.Parameter.set(Robot, [:calibration, :neutral], 1520)
    assert_receive {:pulse, 0, 1716}
  end

  test "throttle left over from before a disarm isn't rewritten by a calibration change" do
    :ok = BB.Actuator.set_velocity(Robot, :esc, 0.2 * @full, delivery: :pubsub, duration: 5000)
    assert_receive {:pulse, 0, 1600}
    :ok = BB.Safety.disarm(Robot)
    assert_receive {:pulse, 0, 1500}

    :ok = BB.Parameter.set(Robot, [:calibration, :forward], 2500)
    assert_receive {:pulse, 0, 1500}
    refute_receive {:pulse, 0, 1700}
  end
end
