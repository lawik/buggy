defmodule Buggy.Robot do
  use BB

  commands do
    command :arm do
      handler(BB.Command.Arm)
      allowed_states([:disarmed])
    end

    command :disarm do
      handler(BB.Command.Disarm)
      allowed_states([:idle])
    end
  end

  topology do
    link :base_link do
    end
  end

  controllers do
    controller(
      :pca9685,
      {BB.Servo.PCA9685.Controller,
       bus: param([:config, :pca9685, :bus]), address: param([:config, :pca9685, :address])}
    )
  end

  parameters do
    group :config do
      group :pca9685 do
        param(:bus, type: :string, doc: "I2C bus name (e.g. \"i2c-1\")")

        param(:address, type: :integer, default: 0x40, doc: "I2C address of the PCA9685")
      end
    end
  end
end
