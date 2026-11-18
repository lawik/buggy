defmodule Buggy.BLE.ControlPadTest do
  use ExUnit.Case, async: true

  alias Buggy.BLE.ControlPad

  test "parses Bluefruit Connect's button packets, as it sends them" do
    # Up pressed and released, as the app sends them.
    assert ControlPad.parse("!B516") == {:ok, {:pressed, :up}}
    assert ControlPad.parse("!B507") == {:ok, {:released, :up}}

    for {button, char} <- [{1, ?1}, {4, ?4}, {:down, ?6}, {:left, ?7}, {:right, ?8}],
        action <- [:pressed, :released] do
      packet = ControlPad.packet({action, button})
      assert <<"!B", ^char, _state, _checksum>> = packet
      assert ControlPad.parse(packet) == {:ok, {action, button}}
    end
  end

  test "ignores bad checksums and the pad's other packets, and leaves text alone" do
    assert ControlPad.parse("!B517") == :ignore
    # A colour packet: "!C", red, green, blue, checksum.
    colour = <<"!C", 255, 0, 0>>
    assert ControlPad.parse(colour <> <<ControlPad.checksum(colour)>>) == :ignore
    assert ControlPad.parse("help\n") == :not_a_packet
    assert ControlPad.parse("!Contact") == :not_a_packet
  end

  test "held arrows are Donkey Car throttle and steering, opposites cancelling" do
    pad = apply_events(%ControlPad{}, [{:pressed, :up}, {:pressed, :left}])
    assert ControlPad.drive(pad) == {1.0, -1.0}

    pad = ControlPad.apply_event(pad, {:pressed, :right})
    assert ControlPad.drive(pad) == {1.0, 0.0}

    pad = apply_events(pad, [{:released, :up}, {:released, :left}, {:pressed, :down}])
    assert ControlPad.drive(pad) == {-1.0, 1.0}
    refute ControlPad.released?(pad)

    pad = apply_events(pad, [{:released, :down}, {:released, :right}])
    assert ControlPad.released?(pad)
    assert ControlPad.drive(pad) == {0.0, 0.0}
  end

  test "numbered buttons don't drive" do
    assert ControlPad.apply_event(%ControlPad{}, {:pressed, 1}) == %ControlPad{}
  end

  defp apply_events(pad, events), do: Enum.reduce(events, pad, &ControlPad.apply_event(&2, &1))
end
