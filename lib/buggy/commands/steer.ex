defmodule Buggy.Commands.Steer do
  @moduledoc "Set the steering, `-1.0` (full left) to `1.0` (full right)."
  use BB.Command

  @impl BB.Command
  def handle_command(goal, context, state) do
    result = Buggy.Drive.steer(goal.steering, context.robot_module)
    {:stop, :normal, Map.put(state, :result, result)}
  end

  @impl BB.Command
  def result(%{result: result}), do: result
end
