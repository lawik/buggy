defmodule Buggy.ParameterStore do
  @moduledoc """
  `BB.Parameter.Store.Dets`, made safe for a car that's switched off by
  cutting its power.

  The Dets store only inserts, and opens its table with `auto_save:
  :infinity`, so a change can sit in DETS's write cache with nothing to flush
  it. This syncs after every save instead, and once on opening, so a newly
  created file's header is on disk too. Changes are rare (calibration, the
  throttle cap), so that costs nothing noticeable. It also creates the file's
  directory, which DETS won't.

  A file DETS can't read is moved aside and replaced with a fresh one. On the
  car that was an empty file, most likely from the power going while it was
  first being created, and DETS refused it at every boot, which left the robot
  with no store at all: nothing was restored and nothing saved, with only a
  warning at boot to show for it. The old file is kept next to the new one,
  named `<path>.unreadable-<unix time>`.

  The store has no way to delete a value, so `forget/2` does that from
  outside it, for `Buggy.Parameters.unset/2`.
  """
  @behaviour BB.Parameter.Store

  require Logger

  alias BB.Parameter.Store.Dets

  @impl BB.Parameter.Store
  def init(robot_module, opts) do
    with {:ok, path} <- Keyword.fetch(opts, :path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, %Dets{table: table} = state} <- open(robot_module, opts, path),
         :ok <- :dets.sync(table) do
      # Once per robot start, so the cost of a persistent_term write is fine.
      :persistent_term.put({__MODULE__, robot_module}, table)
      {:ok, state}
    else
      :error -> {:error, {:missing_option, :path}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A `file_error` is the filesystem (permissions, I/O), which a new file
  # wouldn't fix. Anything else means DETS couldn't make sense of the file.
  defp open(robot_module, opts, path) do
    case Dets.init(robot_module, opts) do
      {:error, {:dets_open_failed, {:file_error, _, _}}} = error ->
        error

      {:error, {:dets_open_failed, reason}} ->
        aside = "#{path}.unreadable-#{System.os_time(:second)}"

        Logger.warning(
          "Parameter store #{path} is unreadable (#{inspect(reason)}), " <>
            "so it's been moved to #{aside} and a fresh one started"
        )

        with :ok <- File.rename(path, aside), do: Dets.init(robot_module, opts)

      result ->
        result
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
