defmodule Buggy.Drive do
  @moduledoc """
  Steering and throttle in Donkey Car conventions, both normalised to
  `-1.0..1.0`:

    * `steering`: `-1.0` full left, `0.0` straight ahead, `1.0` full right
    * `throttle`: `-1.0` full reverse, `0.0` stopped, `1.0` full forward.
      The ESC caps the magnitude at its `max_throttle`.

  These go straight to the actuators, so the robot has to be armed. The
  robot's drive commands are built on them, and they work from IEx as well:

      Buggy.Robot.arm() |> then(fn {:ok, c} -> BB.Command.await(c) end)
      Buggy.Drive.steer(-0.5)
      Buggy.Drive.throttle(0.2, 500)
      Buggy.Drive.stop()
  """

  alias BB.Actuator

  @robot Buggy.Robot
  @steering_joint :steering
  @steering_actuator :steering_servo
  @drive_joint :drive
  @esc :esc

  @doc "Turn the front wheels. Returns the joint angle commanded, in degrees."
  @spec steer(number(), module()) :: {:ok, map()} | {:error, term()}
  def steer(steering, robot \\ @robot) do
    steering = clamp(steering * 1.0)
    %{lower: lower, upper: upper} = limits(robot, @steering_joint)

    # The joint follows the ROS convention (positive yaw is to the left), so
    # left (negative steering) maps onto the upper limit.
    angle =
      cond do
        steering < 0 -> -steering * upper
        steering > 0 -> steering * lower
        true -> 0.0
      end

    with :ok <- Actuator.set_position(robot, @steering_actuator, angle) do
      {:ok, %{steering: steering, angle_deg: Float.round(angle * 180 / :math.pi(), 1)}}
    end
  end

  @doc """
  Run the drive motor for `duration_ms`, after which the ESC returns itself
  to neutral.
  """
  @spec throttle(number(), pos_integer(), module()) :: {:ok, map()} | {:error, term()}
  def throttle(throttle, duration_ms, robot \\ @robot) do
    throttle = clamp(throttle * 1.0)
    %{velocity: velocity_limit} = limits(robot, @drive_joint)

    with :ok <-
           Actuator.set_velocity(robot, @esc, throttle * velocity_limit,
             duration: duration_ms,
             delivery: :pubsub
           ) do
      {:ok, %{throttle: throttle, duration_ms: duration_ms}}
    end
  end

  @doc "Throttle to neutral."
  @spec stop_throttle(module()) :: :ok | {:error, term()}
  def stop_throttle(robot \\ @robot), do: Actuator.stop(robot, @esc, delivery: :pubsub)

  @doc "Throttle to neutral and steering straight ahead."
  @spec stop(module()) :: {:ok, map()} | {:error, term()}
  def stop(robot \\ @robot) do
    with :ok <- stop_throttle(robot),
         {:ok, _} <- steer(0.0, robot) do
      {:ok, %{throttle: 0.0, steering: 0.0}}
    end
  end

  defp limits(robot, joint_name) do
    {:ok, joint} = BB.Robot.get_joint(robot.robot(), joint_name)
    joint.limits
  end

  defp clamp(value), do: value |> max(-1.0) |> min(1.0)
end
