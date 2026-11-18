defmodule Buggy.BLE.AdvertisingTest do
  use ExUnit.Case, async: true

  alias Buggy.BLE.{Advertising, Improv}

  @uart 0x6E400001_B5A3_F393_E0A9_E50E24DCCA9E

  test "the advertisement carries Improv's UUID and state, in exactly 31 bytes" do
    adv = Advertising.advertising_data(Improv.authorized())
    assert byte_size(adv) == 31

    assert [
             {0x01, <<0x06>>},
             {0x07, <<uuid::little-128>>},
             {0x16, <<0x4677::little-16, 0x02, 0, 0, 0, 0, 0>>}
           ] = structures(adv)

    assert uuid == Improv.service_uuid()
  end

  test "the scan response has the name and the UART service" do
    scan = Advertising.scan_response("buggy-b925", @uart)
    assert byte_size(scan) <= 31
    assert [{0x09, "buggy-b925"}, {0x06, <<@uart::little-128>>}] = structures(scan)
  end

  test "a long name is shortened to fit" do
    scan = Advertising.scan_response("a-buggy-with-a-long-name", @uart)
    assert byte_size(scan) == 31
    # 31 bytes, less the UUID's 18 and the name's own 2.
    assert [{0x08, "a-buggy-wit"}, {0x06, _uuid}] = structures(scan)
  end

  defp structures(<<>>), do: []

  defp structures(<<length, type, data::binary-size(length - 1), rest::binary>>),
    do: [{type, data} | structures(rest)]
end
