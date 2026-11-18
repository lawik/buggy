defmodule Buggy.WiFiTest do
  use ExUnit.Case, async: false

  alias Buggy.Test.FakeVintageNet
  alias Buggy.WiFi

  @opts [vintage_net: FakeVintageNet, timeout_ms: 200]

  setup do
    start_supervised!(
      {FakeVintageNet,
       ssid: "Home", psk: "home-password", reachable: %{"Home" => "home-password", "Cafe" => ""}}
    )

    :ok
  end

  test "status reports the network and address, without wpa_supplicant's current AP" do
    assert WiFi.status(@opts) == %{ssid: "Home", connection: :internet, address: "10.0.0.7"}
  end

  test "joins a reachable network and keeps it" do
    assert {:ok, %{ssid: "Cafe", address: "10.0.0.7"}} = WiFi.join("Cafe", "", @opts)

    assert [%{vintage_net_wifi: %{networks: [%{ssid: "Cafe", key_mgmt: :none}]}}] =
             FakeVintageNet.configured()

    assert WiFi.status(@opts).ssid == "Cafe"
  end

  # Right after configuring, the old network's connection and address are
  # still reported: they mustn't pass for the new network's.
  test "goes back to the previous network when the new one doesn't connect" do
    assert {:error, :unable_to_connect} = WiFi.join("Home", "wrong-password", @opts)

    assert [%{vintage_net_wifi: %{networks: [%{psk: "wrong-password"}]}}, restored] =
             FakeVintageNet.configured()

    assert restored == WiFi.config("Home", "home-password")
  end

  test "joining the network it's on is done at once" do
    assert {:ok, %{ssid: "Home"}} = WiFi.join("Home", "home-password", @opts)
    assert FakeVintageNet.configured() == []
  end

  test "a configuration VintageNet refuses is reported, and nothing changes" do
    assert {:error, {:invalid, :bad_psk}} = WiFi.join("Home", "short", @opts)
    assert FakeVintageNet.configured() == []
  end

  test "leaves no subscription or change messages behind" do
    {:ok, _} = WiFi.join("Cafe", "", @opts)
    Process.sleep(50)
    refute_received {VintageNet, _, _, _, _}
  end
end
