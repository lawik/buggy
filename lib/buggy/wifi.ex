defmodule Buggy.WiFi do
  @moduledoc """
  Joining a Wi-Fi network at run time, for provisioning over BLE.

  `join/3` replaces wlan0's networks with the new one and waits for it to
  connect. If it hasn't within the timeout (a wrong password, or the network
  isn't in range), the previous configuration goes back, so a typo doesn't
  strand the car off the network. VintageNet saves the configuration, so a
  joined network is used again after a reboot.

  VintageNet only runs on the device; tests pass a stand-in as
  `:vintage_net`.
  """

  require Logger

  @ifname "wlan0"
  @connection ["interface", @ifname, "connection"]
  @timeout_ms 30_000

  @type status :: %{
          ssid: String.t() | nil,
          connection: atom(),
          address: String.t() | nil
        }

  @doc """
  The network wlan0 is on, how connected it is, and its IPv4 address.

  The SSID is `nil` while it isn't connected, and also when it's connected
  but configured with several networks and wpa_supplicant hasn't said which.
  """
  @spec status(keyword()) :: status()
  def status(opts \\ []) do
    vintage_net = vintage_net(opts)
    connection = vintage_net.get(@connection) || :disconnected

    %{
      ssid: if(connected?(connection), do: ssid(vintage_net)),
      connection: connection,
      address: ipv4_address(vintage_net)
    }
  end

  @doc """
  Join `ssid`, with `psk` for WPA/WPA2 Personal or `""` for an open network.

  Blocks until connected, or until `:timeout_ms` (default #{@timeout_ms})
  has passed and the previous configuration is restored.
  """
  @spec join(String.t(), String.t(), keyword()) ::
          {:ok, status()} | {:error, :unable_to_connect | {:invalid, term()}}
  def join(ssid, psk, opts \\ []) do
    vintage_net = vintage_net(opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, @timeout_ms)
    previous = vintage_net.get_configuration(@ifname)

    # Before configuring, so no change of connection can be missed.
    :ok = vintage_net.subscribe(@connection)

    try do
      with :ok <- vintage_net.configure(@ifname, config(ssid, psk)) do
        Logger.info("Joining Wi-Fi network #{inspect(ssid)}")
        deadline = System.monotonic_time(:millisecond) + timeout_ms

        # VintageNet leaves an unchanged configuration alone: no reconnecting
        # to wait for, so being connected now is on this network.
        settled? = vintage_net.get_configuration(@ifname) == previous

        case await_connection(vintage_net, settled?, deadline) do
          {:ok, status} ->
            Logger.info("Joined #{inspect(ssid)} as #{status.address}")
            {:ok, %{status | ssid: ssid}}

          :timeout ->
            Logger.warning("Couldn't join #{inspect(ssid)}, restoring the previous Wi-Fi")
            restore(vintage_net, previous)
            {:error, :unable_to_connect}
        end
      else
        {:error, reason} -> {:error, {:invalid, reason}}
      end
    after
      vintage_net.unsubscribe(@connection)
      flush_connection_changes()
    end
  end

  @doc "The wlan0 configuration for one network."
  @spec config(String.t(), String.t()) :: map()
  def config(ssid, psk) do
    network =
      if psk in [nil, ""],
        do: %{ssid: ssid, key_mgmt: :none},
        else: %{ssid: ssid, psk: psk, key_mgmt: :wpa_psk}

    %{
      type: VintageNetWiFi,
      ipv4: %{method: :dhcp},
      vintage_net_wifi: %{networks: [network]}
    }
  end

  # A new configuration takes wlan0 down first (VintageNet reports it
  # disconnected), so until that's happened, a connection and address are
  # still the old network's. After it, connected with an address is the new
  # one: it's the only network configured.
  defp await_connection(vintage_net, settled?, deadline) do
    status = status(vintage_net: vintage_net)
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    cond do
      settled? and connected?(status.connection) and status.address != nil ->
        {:ok, status}

      wait == 0 ->
        :timeout

      true ->
        # Also wakes now and then: the address can follow the connection.
        receive do
          {VintageNet, @connection, _old, new, _meta} ->
            await_connection(vintage_net, settled? or not connected?(new), deadline)
        after
          min(wait, 1_000) -> await_connection(vintage_net, settled?, deadline)
        end
    end
  end

  defp restore(vintage_net, previous) do
    case vintage_net.configure(@ifname, previous) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Restoring the Wi-Fi failed: #{inspect(reason)}")
    end
  end

  defp flush_connection_changes do
    receive do
      {VintageNet, @connection, _old, _new, _meta} -> flush_connection_changes()
    after
      0 -> :ok
    end
  end

  defp connected?(connection), do: connection in [:lan, :internet]

  # wpa_supplicant's access point when VintageNet has it (this car's often
  # doesn't), or else the one network configured.
  defp ssid(vintage_net) do
    with nil <- vintage_net.get(["interface", @ifname, "wifi", "current_ap"]),
         %{vintage_net_wifi: %{networks: [%{ssid: ssid}]}} <-
           vintage_net.get_configuration(@ifname) do
      ssid
    else
      %{ssid: ssid} -> ssid
      _ -> nil
    end
  end

  defp ipv4_address(vintage_net) do
    (vintage_net.get(["interface", @ifname, "addresses"]) || [])
    |> Enum.find_value(fn
      %{family: :inet, address: address} -> address |> :inet.ntoa() |> to_string()
      _ -> nil
    end)
  end

  defp vintage_net(opts), do: Keyword.get(opts, :vintage_net, VintageNet)
end
