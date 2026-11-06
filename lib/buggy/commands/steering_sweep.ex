defmodule Buggy.Commands.SteeringSweep do
  @moduledoc """
  Sweep the steering centre, full left, centre, full right, centre, pausing
  `dwell_ms` at each, to check direction and travel.
  """
  use BB.Command

  @sequence [0.0, -1.0, 0.0, 1.0, 0.0]

  @impl BB.Command
  def handle_command(goal, context, state) do
    state
    |> Map.merge(%{
      robot: context.robot_module,
      dwell_ms: goal.dwell_ms,
      todo: @sequence,
      done: []
    })
    |> step()
  end

  @impl BB.Command
  def handle_info(:step, state), do: step(state)
  def handle_info(_msg, state), do: {:noreply, state}

  @impl BB.Command
  def result(%{result: result}), do: result

  defp step(%{todo: []} = state),
    do: {:stop, :normal, Map.put(state, :result, {:ok, %{angles_deg: Enum.reverse(state.done)}})}

  defp step(%{todo: [steering | rest]} = state) do
    case Buggy.Drive.steer(steering, state.robot) do
      {:ok, %{angle_deg: angle}} ->
        Process.send_after(self(), :step, state.dwell_ms)
        {:noreply, %{state | todo: rest, done: [angle | state.done]}}

      {:error, _} = error ->
        {:stop, :normal, Map.put(state, :result, error)}
    end
  end
end
