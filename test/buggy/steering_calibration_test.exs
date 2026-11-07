defmodule Buggy.SteeringCalibrationTest do
  use ExUnit.Case, async: false

  # Records every pulse width written, standing in for the PCA9685.
  defmodule StubPWM do
    use BB.Controller

    @impl BB.Controller
    def init(_opts), do: {:ok, %{}}

    @impl BB.Controller
    def handle_call({:pulse_width, channel, us}, _from, state) do
      if pid = Process.whereis(:steering_test_listener), do: send(pid, {:pulse, channel, us})
      {:reply, :ok, state}
    end
  end

  # The steering joint as Buggy.Robot declares it, with the stub controller.
  defmodule Robot do
    use BB

    topology do
      link :base do
        joint :steering do
          type(:revolute)

          limit do
            lower(~u(-25 degree))
            upper(~u(25 degree))
            effort(~u(1 newton_meter))
            velocity(~u(300 degree_per_second))
          end

          actuator(
            :steering_servo,
            {BB.Servo.PCA9685.Actuator,
             channel: 1,
             controller: :pwm,
             min_pulse: param([:calibration, :steering_right_pulse]),
             max_pulse: param([:calibration, :steering_left_pulse])}
          )

          sensor(
            :steering_feedback,
            {BB.Sensor.OpenLoopPositionEstimator, actuator: :steering_servo}
          )

          link :front_axle do
          end
        end
      end
    end

    controllers do
      controller(:pwm, Buggy.SteeringCalibrationTest.StubPWM)
    end

    parameters do
      group :calibration do
        param(:steering_left_pulse, type: :integer, default: 1800, min: 500, max: 2500)
        param(:steering_right_pulse, type: :integer, default: 1200, min: 500, max: 2500)
      end
    end
  end

  setup do
    Process.register(self(), :steering_test_listener)
    start_supervised!(Robot)
    # Centred on start-up.
    assert_receive {:pulse, 1, 1500}
    :ok = BB.Safety.arm(Robot)
    on_exit(fn -> BB.Safety.disarm(Robot) end)
    :ok
  end

  test "full lock follows the calibration parameters, live" do
    {:ok, %{angle_deg: 25.0}} = Buggy.Drive.steer(-1.0, Robot)
    assert_receive {:pulse, 1, 1800}

    # Holding full left, widen the left pulse: the servo moves at once.
    :ok = BB.Parameter.set(Robot, [:calibration, :steering_left_pulse], 2000)
    assert_receive {:pulse, 1, 2000}

    # The right lock uses the new right pulse; centre is now their midpoint.
    :ok = BB.Parameter.set(Robot, [:calibration, :steering_right_pulse], 1000)
    {:ok, _} = Buggy.Drive.steer(1.0, Robot)
    assert_receive {:pulse, 1, 1000}
    {:ok, _} = Buggy.Drive.steer(0.0, Robot)
    assert_receive {:pulse, 1, 1500}
  end
end
