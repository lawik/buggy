defmodule Buggy.Distribution do
  @moduledoc """
  Erlang distribution as `buggy@<wlan0 IPv4 address>`, e.g.
  `buggy@192.168.1.10`.

  The node is named by IP rather than by mDNS name because the AtomVM badge
  can't resolve mDNS, and a node only accepts connections addressed to the
  exact name it was started with. It starts once wlan0 has an address, and
  restarts under the new name if the address changes.

  Attach from a dev machine with, e.g.:

      iex --name me@<your ip> --cookie buggy_cookie --remsh buggy@192.168.1.10
      mix bb.tui --node buggy@192.168.1.10

  The cookie is the release cookie set in mix.exs. Nerves doesn't pass it as
  `-setcookie`, so a node started at runtime would otherwise get a random one.
  """
  use GenServer

  require Logger

  # Only started on the device; the host doesn't have vintage_net.
  @compile {:no_warn_undefined, VintageNet}

  @interface "wlan0"
  @retry_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    property = ["interface", Keyword.get(opts, :interface, @interface), "addresses"]
    VintageNet.subscribe(property)
    {:ok, %{property: property, ip: nil}, {:continue, :check}}
  end

  @impl GenServer
  def handle_continue(:check, state), do: {:noreply, check(state)}

  @impl GenServer
  def handle_info({VintageNet, property, _old, _new, _meta}, %{property: property} = state) do
    {:noreply, check(state)}
  end

  def handle_info(:retry, state), do: {:noreply, check(state)}

  # With no address the node stays up under its old name: nothing can reach
  # it meanwhile, and it's renamed once an address comes back.
  defp check(state) do
    case ipv4(VintageNet.get(state.property)) do
      nil ->
        state

      ip when ip == state.ip ->
        state

      ip ->
        case start(:"buggy@#{ip}") do
          :ok ->
            %{state | ip: ip}

          {:error, reason} ->
            Logger.warning("Erlang distribution not started: #{inspect(reason)}")
            Process.send_after(self(), :retry, @retry_ms)
            state
        end
    end
  end

  defp ipv4(addresses) when is_list(addresses) do
    Enum.find_value(addresses, fn
      %{family: :inet, address: address} -> address |> :inet.ntoa() |> to_string()
      _ -> nil
    end)
  end

  defp ipv4(_), do: nil

  defp start(name) when name == node(), do: :ok

  defp start(name) do
    if Node.alive?(), do: Node.stop()

    with {_, 0} <- System.cmd("epmd", ["-daemon"]),
         {:ok, _} <- Node.start(name, :longnames),
         {:ok, cookie} <- File.read(cookie_file()) do
      # The release's own cookie file: one atom, not outside input.
      Node.set_cookie(cookie |> String.trim() |> String.to_atom())
      Logger.info("Erlang distribution started as #{name}")
      :ok
    else
      {output, status} when is_integer(status) -> {:error, {:epmd, status, output}}
      {:error, _} = error -> error
    end
  end

  defp cookie_file, do: Path.join([:code.root_dir(), "releases", "COOKIE"])
end
