defmodule Buggy.ParameterStore do
  @moduledoc """
  `BB.Parameter.Store.Dets`, made safe for a car that's switched off by
  cutting its power.

  The Dets store only inserts, and opens its table with `auto_save:
  :infinity`, so a change can sit in DETS's write cache with nothing to flush
  it. This syncs after every save instead. Changes are rare (calibration, the
  throttle cap), so that costs nothing noticeable. It also creates the file's
  directory, which DETS won't.

  The store has no way to delete a value, so `forget/2` does that from
  outside it, for `Buggy.Parameters.unset/2`.
  """
  @behaviour BB.Parameter.Store

  alias BB.Parameter.Store.Dets

  @impl BB.Parameter.Store
  def init(robot_module, opts) do
    with {:ok, path} <- Keyword.fetch(opts, :path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, %Dets{table: table}} = ok <- Dets.init(robot_module, opts) do
      # Once per robot start, so the cost of a persistent_term write is fine.
      :persistent_term.put({__MODULE__, robot_module}, table)
      ok
    else
      :error -> {:error, {:missing_option, :path}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl BB.Parameter.Store
  defdelegate load(state), to: Dets

  @impl BB.Parameter.Store
  def save(%Dets{table: table} = state, path, value) do
    with :ok <- Dets.save(state, path, value) do
      :dets.sync(table)
    end
  end

  @impl BB.Parameter.Store
  defdelegate close(state), to: Dets

  @doc """
  Delete a parameter's saved value, so the robot starts with its default
  again. `:ok` when nothing was saved, or the robot keeps no store (as on the
  host).
  """
  @spec forget(module(), [atom()]) :: :ok | {:error, term()}
  def forget(robot_module, path) do
    case :persistent_term.get({__MODULE__, robot_module}, nil) do
      nil ->
        :ok

      table ->
        with :ok <- :dets.delete(table, {:param, path}) do
          :dets.sync(table)
        end
    end
  rescue
    # The table was closed: the robot is restarting, and will reopen it.
    ArgumentError -> {:error, :store_closed}
  end
end
