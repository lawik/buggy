defmodule Buggy.Robot do
  use BB

  # PCA9685 wiring, using the Donkey Car defaults: steering servo on channel 1,
  # ESC on channel 0.
  @steering_channel 1
  @throttle_channel 0

  # Steering full-lock pulses are the calibration.steering_*_pulse parameters,
  # adjustable live: hold full lock (`steer -1.0` / `1.0`) and move the pulse
  # until the wheels just reach their stop. The ESC's are calibration.esc_*:
  # trim neutral (written straight away, even disarmed) until the ESC stops
  # humming and arms.

  # On the device, parameter changes (calibration, the throttle cap) are saved
  # to /data and restored at boot, so they survive reboots and firmware
  # updates. Saved values win over the defaults below, so a changed default
  # only applies once that parameter is set again (or the file is deleted).
  # On the host (simulation and tests), every start uses the defaults.
  if Mix.target() != :host do
    settings do
      parameter_store({Buggy.ParameterStore, path: "/data/buggy/parameters.dets"})
    end
  end

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
        doc: "-1.0 full reverse to 1.0 full forward, capped at the limits.max_throttle parameter"
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

  # Dimensions are typical of a 1/16 Donkey Car: 20 cm wheelbase, 16 cm
  # track, 66 mm wheels. Adjust to the real car; only the 3D view uses them.
  topology do
    link :base_link do
      visual do
        origin do
          z(~u(0.015 meter))
        end

        box do
          x(~u(0.26 meter))
          y(~u(0.10 meter))
          z(~u(0.03 meter))
        end

        material do
          name(:chassis)

          color do
            red(0.25)
            green(0.27)
            blue(0.3)
            alpha(1.0)
          end
        end
      end

      # Pi Camera v1 (OV5647) on the CSI port, over WebRTC, plus decoded
      # frames for whoever subscribes to its images. Its settings are the
      # video.* parameters below.
      sensor(
        :camera,
        {Buggy.Sensor.Camera,
         resolution: param([:video, :resolution]),
         sensor_mode: param([:video, :sensor_mode]),
         framerate: param([:video, :framerate]),
         bitrate_kbps: param([:video, :bitrate_kbps]),
         keyframe_interval: param([:video, :keyframe_interval]),
         exposure: param([:video, :exposure]),
         ev: param([:video, :ev]),
         sharpness: param([:video, :sharpness]),
         denoise: param([:video, :denoise]),
         rotate_180: param([:video, :rotate_180])}
      )

      joint :camera_mount do
        type(:fixed)

        origin do
          x(~u(0.11 meter))
          z(~u(0.06 meter))
        end

        link :camera_housing do
          visual do
            box do
              x(~u(0.02 meter))
              y(~u(0.03 meter))
              z(~u(0.025 meter))
            end

            material do
              name(:camera_case)

              color do
                red(0.1)
                green(0.3)
                blue(0.15)
                alpha(1.0)
              end
            end
          end
        end
      end

      # The servo's joint: what steering commands, the dashboard and the TUI
      # see. Positive is to the left. The knuckles below mimic it.
      joint :steering do
        type(:revolute)

        origin do
          x(~u(0.10 meter))
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
           min_pulse: param([:calibration, :steering_right_pulse]),
           max_pulse: param([:calibration, :steering_left_pulse])}
        )

        sensor(
          :steering_feedback,
          {BB.Sensor.OpenLoopPositionEstimator, actuator: :steering_servo}
        )

        link :steering_input do
        end
      end

      # The left steering knuckle follows the servo's joint through the linkage.
      joint :front_left_steer do
        type(:revolute)

        origin do
          x(~u(0.10 meter))
          y(~u(0.08 meter))
        end

        limit do
          lower(~u(-25 degree))
          upper(~u(25 degree))
          effort(~u(1 newton_meter))
          velocity(~u(300 degree_per_second))
        end

        sensor(:front_left_linkage, {BB.Sensor.Mimic, source: :steering})

        link :front_left_wheel do
          visual do
            # Cylinders run along Z; roll them onto their edge.
            origin do
              roll(~u(90 degree))
            end

            cylinder do
              radius(~u(0.033 meter))
              height(~u(0.025 meter))
            end

            material do
              name(:front_left_tyre)

              color do
                red(0.08)
                green(0.08)
                blue(0.08)
                alpha(1.0)
              end
            end
          end
        end
      end

      # The right steering knuckle follows the servo's joint through the linkage.
      joint :front_right_steer do
        type(:revolute)

        origin do
          x(~u(0.10 meter))
          y(~u(-0.08 meter))
        end

        limit do
          lower(~u(-25 degree))
          upper(~u(25 degree))
          effort(~u(1 newton_meter))
          velocity(~u(300 degree_per_second))
        end

        sensor(:front_right_linkage, {BB.Sensor.Mimic, source: :steering})

        link :front_right_wheel do
          visual do
            # Cylinders run along Z; roll them onto their edge.
            origin do
              roll(~u(90 degree))
            end

            cylinder do
              radius(~u(0.033 meter))
              height(~u(0.025 meter))
            end

            material do
              name(:front_right_tyre)

              color do
                red(0.08)
                green(0.08)
                blue(0.08)
                alpha(1.0)
              end
            end
          end
        end
      end

      joint :drive do
        type(:continuous)

        origin do
          x(~u(-0.10 meter))
        end

        # The rear axle turns about +Y, so forward is positive.
        axis do
          roll(~u(-90 degree))
        end

        # The velocity limit is notional: it's what the ESC treats as full
        # throttle, so throttle = velocity / limit.
        limit do
          effort(~u(1 newton_meter))
          velocity(~u(3600 degree_per_second))
        end

        actuator(
          :esc,
          {Buggy.Actuator.ESC,
           channel: @throttle_channel,
           controller: :pca9685,
           neutral_pulse: param([:calibration, :esc_neutral_pulse]),
           forward_pulse: param([:calibration, :esc_forward_pulse]),
           reverse_pulse: param([:calibration, :esc_reverse_pulse]),
           max_throttle: param([:limits, :max_throttle])}
        )

        link :rear_axle do
          visual do
            origin do
              roll(~u(90 degree))
            end

            cylinder do
              radius(~u(0.004 meter))
              height(~u(0.16 meter))
            end

            material do
              name(:axle)

              color do
                red(0.6)
                green(0.6)
                blue(0.6)
                alpha(1.0)
              end
            end
          end

          joint :rear_left_hub do
            type(:fixed)

            origin do
              y(~u(0.08 meter))
            end

            link :rear_left_wheel do
              visual do
                # Cylinders run along Z; roll them onto their edge.
                origin do
                  roll(~u(90 degree))
                end

                cylinder do
                  radius(~u(0.033 meter))
                  height(~u(0.025 meter))
                end

                material do
                  name(:rear_left_tyre)

                  color do
                    red(0.08)
                    green(0.08)
                    blue(0.08)
                    alpha(1.0)
                  end
                end
              end
            end
          end

          joint :rear_right_hub do
            type(:fixed)

            origin do
              y(~u(-0.08 meter))
            end

            link :rear_right_wheel do
              visual do
                # Cylinders run along Z; roll them onto their edge.
                origin do
                  roll(~u(90 degree))
                end

                cylinder do
                  radius(~u(0.033 meter))
                  height(~u(0.025 meter))
                end

                material do
                  name(:rear_right_tyre)

                  color do
                    red(0.08)
                    green(0.08)
                    blue(0.08)
                    alpha(1.0)
                  end
                end
              end
            end
          end
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
    group :limits do
      param(:max_throttle,
        type: :float,
        default: 0.3,
        min: 0.0,
        max: 1.0,
        doc: "Cap on throttle magnitude (0.0-1.0), applied by the ESC to every command"
      )
    end

    # Uncalibrated starting points. If the wheels turn the wrong way, swap them.
    group :calibration do
      param(:steering_left_pulse,
        type: :integer,
        default: 1800,
        min: 500,
        max: 2500,
        doc: "Steering servo pulse (µs) at full left lock"
      )

      param(:steering_right_pulse,
        type: :integer,
        default: 1200,
        min: 500,
        max: 2500,
        doc: "Steering servo pulse (µs) at full right lock"
      )

      # The ESC only arms, and stays quiet, when it sees the neutral it
      # expects, and the PCA9685's clock can be several percent off. A change
      # is written at once, disarmed too, so trim neutral until the hum stops.
      # It's kept near 1500 because it's sent while disarmed.
      param(:esc_neutral_pulse,
        type: :integer,
        default: 1500,
        min: 1300,
        max: 1700,
        doc: "ESC pulse (µs) for stopped, also sent while disarmed"
      )

      param(:esc_forward_pulse,
        type: :integer,
        default: 2000,
        min: 500,
        max: 2500,
        doc: "ESC pulse (µs) at full forward (before the max_throttle cap)"
      )

      param(:esc_reverse_pulse,
        type: :integer,
        default: 1000,
        min: 500,
        max: 2500,
        doc: "ESC pulse (µs) at full reverse (before the max_throttle cap)"
      )
    end

    # Live camera settings, checked by Buggy.Camera.Settings (which also has
    # the OV5647's sensor modes). Changing one restarts rpicam-vid, and the
    # dashboard's video comes back by itself a couple of seconds later.
    group :video do
      param(:resolution,
        type: :string,
        default: "640x480",
        doc: "Video size, WIDTHxHEIGHT in even numbers, up to 1920x1080"
      )

      param(:sensor_mode,
        type: :string,
        default: "auto",
        doc: "Sensor readout: auto, 640x480, 1296x972 (sharpest full view), 1920x1080 (crop)"
      )

      param(:framerate,
        type: :integer,
        default: 30,
        min: 5,
        max: 60,
        doc: "Frames per second, capped by the sensor mode"
      )

      param(:bitrate_kbps,
        type: :integer,
        default: 1500,
        min: 250,
        max: 10_000,
        doc: "H.264 bitrate in kbit/s"
      )

      param(:keyframe_interval,
        type: :float,
        default: 1.0,
        min: 0.25,
        max: 5.0,
        doc: "Seconds between keyframes: the longest a new viewer waits for a picture"
      )

      param(:exposure,
        type: :string,
        default: "normal",
        doc: "normal, sport (short exposures, less motion blur), short or long"
      )

      param(:ev,
        type: :float,
        default: 0.0,
        min: -4.0,
        max: 4.0,
        doc: "Exposure compensation in stops"
      )

      param(:sharpness,
        type: :float,
        default: 1.0,
        min: 0.0,
        max: 4.0,
        doc: "Sharpening: 0 none, 1 normal"
      )

      param(:denoise,
        type: :string,
        default: "auto",
        doc: "auto, off, cdn_off, cdn_fast or cdn_hq"
      )

      param(:rotate_180, type: :boolean, default: false, doc: "Camera mounted upside down")
    end

    group :config do
      group :motorcontrol do
        param(:bus, type: :string, doc: "I2C bus name (e.g. \"i2c-1\")")

        param(:address, type: :integer, default: 0x40, doc: "I2C address of the PCA9685")
      end
    end
  end
end
