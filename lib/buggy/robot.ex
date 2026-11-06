defmodule Buggy.Robot do
  use BB

  # PCA9685 wiring, using the Donkey Car defaults: steering servo on channel 1,
  # ESC on channel 0.
  @steering_channel 1
  @throttle_channel 0

  # Steering servo pulse widths (µs) at full lock. Uncalibrated starting
  # points: if the wheels turn the wrong way, swap them.
  @steering_left_pulse 1800
  @steering_right_pulse 1200

  # Every command shares the default category (one at a time), and each drive
  # command, and disarm, cancels whatever is running so the newest one wins.
  # (A custom category would be neater, but bb_liveview's command panel
  # crashes on category entities.)
  commands do
    command :arm do
      handler(BB.Command.Arm)
      allowed_states([:disarmed])
    end

    command :disarm do
      handler(BB.Command.Disarm)
      allowed_states([:idle])
      cancel([:default])
    end

    command :steer do
      handler(Buggy.Commands.Steer)
      allowed_states([:idle])
      cancel([:default])

      argument(:steering, :float,
        default: 0.0,
        doc: "-1.0 full left, 0.0 straight, 1.0 full right"
      )
    end

    command :throttle do
      handler(Buggy.Commands.Throttle)
      allowed_states([:idle])
      cancel([:default])

      argument(:throttle, :float,
        default: 0.2,
        doc: "-1.0 full reverse to 1.0 full forward; the ESC caps it at 0.3"
      )

      argument(:duration_ms, :integer, default: 1000, doc: "How long to run before stopping")
    end

    command :steering_sweep do
      handler(Buggy.Commands.SteeringSweep)
      allowed_states([:idle])
      cancel([:default])

      argument(:dwell_ms, :integer, default: 700, doc: "Pause at each position")
    end

    command :stop do
      handler(Buggy.Commands.Stop)
      allowed_states([:idle])
      cancel([:default])
    end
  end

  topology do
    link :base_link do
      visual do
        box do
          x(~u(0.30 meter))
          y(~u(0.18 meter))
          z(~u(0.05 meter))
        end
      end

      joint :steering do
        type(:revolute)

        origin do
          x(~u(0.12 meter))
        end

        limit do
          lower(~u(-25 degree))
          upper(~u(25 degree))
          effort(~u(1 newton_meter))
          velocity(~u(300 degree_per_second))
        end

        actuator(
          :steering_servo,
          {BB.Servo.PCA9685.Actuator,
           channel: @steering_channel,
           controller: :pca9685,
           min_pulse: @steering_right_pulse,
           max_pulse: @steering_left_pulse}
        )

        sensor(
          :steering_feedback,
          {BB.Sensor.OpenLoopPositionEstimator, actuator: :steering_servo}
        )

        link :front_axle do
        end
      end

      joint :drive do
        type(:continuous)

        origin do
          x(~u(-0.12 meter))
        end

        # The velocity limit is notional: it's what the ESC treats as full
        # throttle, so throttle = velocity / limit.
        limit do
          effort(~u(1 newton_meter))
          velocity(~u(3600 degree_per_second))
        end

        actuator(:esc, {Buggy.Actuator.ESC, channel: @throttle_channel, controller: :pca9685})

        link :rear_axle do
        end
      end
    end
  end

  controllers do
    controller(
      :pca9685,
      {BB.Servo.PCA9685.Controller,
       bus: param([:config, :motorcontrol, :bus]),
       address: param([:config, :motorcontrol, :address])}
    )
  end

  parameters do
    group :config do
      group :motorcontrol do
        param(:bus, type: :string, doc: "I2C bus name (e.g. \"i2c-1\")")

        param(:address, type: :integer, default: 0x40, doc: "I2C address of the PCA9685")
      end
    end
  end
end
