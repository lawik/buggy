defmodule Buggy.BLE.ImprovTest do
  use ExUnit.Case, async: true

  alias Buggy.BLE.Improv

  test "the spec's own Wi-Fi settings example" do
    # From improv-wifi.com/ble: SSID MyWirelessAP, password mysecurepassword.
    packet = Improv.encode_wifi_settings("MyWirelessAP", "mysecurepassword")
    assert <<0x01, 0x1E, 0x0C, "MyWirelessAP", 0x10, "mysecurepassword", _sum>> = packet

    assert {:ok, 0x01, data, ""} = Improv.take_command(packet)
    assert Improv.decode_wifi_settings(data) == {:ok, "MyWirelessAP", "mysecurepassword"}
  end

  test "reassembles a command written in 20-byte pieces" do
    packet = Improv.encode_wifi_settings("A network with a long name", "and a long password")
    <<first::binary-size(20), second::binary-size(20), rest::binary>> = packet

    assert Improv.take_command(first) == :incomplete
    assert Improv.take_command(first <> second) == :incomplete
    assert {:ok, 0x01, _data, ""} = Improv.take_command(first <> second <> rest)
  end

  test "keeps what follows a whole command" do
    packet = Improv.encode_command(0x02, "")
    assert {:ok, 0x02, "", "\x01"} = Improv.take_command(packet <> "\x01")
  end

  test "rejects a bad checksum" do
    <<0x02, 0, sum>> = Improv.encode_command(0x02, "")
    assert {:error, :invalid_rpc, ""} = Improv.take_command(<<0x02, 0, sum + 1>>)
  end

  test "an open network has an empty password; an empty SSID is invalid" do
    assert Improv.decode_wifi_settings(<<4, "Cafe", 0>>) == {:ok, "Cafe", ""}
    assert Improv.decode_wifi_settings(<<0, 0>>) == :error
    assert Improv.decode_wifi_settings(<<4, "Cafe">>) == :error
  end

  test "results are length-prefixed strings with a checksum" do
    result = Improv.encode_result(0x01, ["http://x"])
    assert <<0x01, 9, 8, "http://x", sum>> = result
    assert sum == Improv.checksum(<<0x01, 9, 8, "http://x">>)
    assert Improv.encode_result(0x01, []) == <<0x01, 0, 0x01>>
  end
end
