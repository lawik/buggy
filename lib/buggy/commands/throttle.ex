defmodule Buggy.Commands.Throttle do
  @moduledoc """
  Run the drive motor at `throttle` for `duration_ms`, then return to neutral.

  The duration is also handed to the ESC, so the motor stops on time even if
  this command dies. Cancelling it (or running `stop`) stops the motor early.
  """
  use BB.Command

  alias Buggy.Drive

  @impl BB.Command
  def handle_command(goal, context, state) do
    robot = context.robot_module

    case Drive.throttle(goal.throttle, goal.duration_ms, robot) do
      {:ok, applied} ->
        Process.send_after(self(), :done, goal.duration_ms)
        {:noreply, Map.merge(state, %{robot: robot, result: {:ok, applied}})}

      {:error, _} = error ->
        {:stop, :normal, Map.put(state, :result, error)}
    end
  end

  @impl BB.Command
  def handle_info(:done, state) do
    _ = Drive.stop_throttle(state.robot)
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl BB.Command
  def result(%{result: result}), do: result

  # Best effort on the way out, cancelled or not: once disarmed the actuator
  # refuses commands, but disarming has already sent it to neutral.
  @impl BB.Command
  def terminate(_reason, %{robot: robot}), do: Drive.stop_throttle(robot)
  def terminate(_reason, _state), do: :ok
end
