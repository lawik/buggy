defmodule Buggy.Commands.Stop do
  @moduledoc "Throttle to neutral and steering straight ahead, cancelling any running drive command."
  use BB.Command

  @impl BB.Command
  def handle_command(_goal, context, state) do
    {:stop, :normal, Map.put(state, :result, Buggy.Drive.stop(context.robot_module))}
  end

  @impl BB.Command
  def result(%{result: result}), do: result
end
