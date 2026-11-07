defmodule Buggy.ParameterStore do
  @moduledoc """
  `BB.Parameter.Store.Dets`, made safe for a car that's switched off by
  cutting its power.

  The Dets store only inserts, and opens its table with `auto_save:
  :infinity`, so a change can sit in DETS's write cache with nothing to flush
  it. This syncs after every save instead. Changes are rare (calibration, the
  throttle cap), so that costs nothing noticeable. It also creates the file's
  directory, which DETS won't.
  """
  @behaviour BB.Parameter.Store

  alias BB.Parameter.Store.Dets

  @impl BB.Parameter.Store
  def init(robot_module, opts) do
    with {:ok, path} <- Keyword.fetch(opts, :path),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      Dets.init(robot_module, opts)
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
end
