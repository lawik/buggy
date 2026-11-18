defmodule Buggy.BLE.ControlPad do
  @moduledoc """
  Adafruit Bluefruit Connect's Control Pad: the usual way to drive a BLE car
  from a phone without writing an app (iOS and Android, free).

  Bluefruit Connect sends each press and release over the Nordic UART Service
  as a five-byte packet:

      "!B" <> button <> state <> checksum

  `button` is `"1"` to `"8"`: the numbered buttons 1-4, then up (5), down (6),
  left (7) and right (8). `state` is `"1"` for pressed and `"0"` for released,
  and the checksum is the low byte of the complement of the sum of the bytes
  before it. Holding up sends `"!B516"`, letting go `"!B507"`. Nothing is sent
  while a button is held.

  The pad's other packets (colour, and the phone's sensors: quaternion,
  accelerometer, gyro, magnetometer, location) are recognised and ignored.

  The held direction buttons turn into Donkey Car `{throttle, steering}` (see
  `Buggy.Drive`): up and down are full forward and reverse, which the ESC caps
  at the `limits.max_throttle` parameter, and left and right full lock.
  """

  @type direction :: :up | :down | :left | :right
  @type button :: 1..4 | direction()
  @type event :: {:pressed | :released, button()}

  @type t :: %__MODULE__{held: MapSet.t(direction())}
  defstruct held: MapSet.new()

  @buttons %{
    ?1 => 1,
    ?2 => 2,
    ?3 => 3,
    ?4 => 4,
    ?5 => :up,
    ?6 => :down,
    ?7 => :left,
    ?8 => :right
  }

  # Packet letter => total length, checksum included.
  @other_packets %{?C => 6, ?Q => 19, ?A => 15, ?G => 15, ?M => 15, ?L => 15}

  @doc """
  Parse one write to the UART's RX characteristic.

  Returns `{:ok, event}` for a button packet, `:ignore` for the pad's other
  packets and for button packets whose checksum is wrong, and `:not_a_packet`
  for anything else, which is console text.
  """
  @spec parse(binary()) :: {:ok, event()} | :ignore | :not_a_packet
  def parse(<<"!B", button, state, checksum>> = packet)
      when is_map_key(@buttons, button) and state in [?0, ?1] do
    if checksum(binary_part(packet, 0, 4)) == checksum do
      {:ok, {if(state == ?1, do: :pressed, else: :released), Map.fetch!(@buttons, button)}}
    else
      :ignore
    end
  end

  def parse(<<"!", letter, _::binary>> = packet)
      when letter == ?B or is_map_key(@other_packets, letter) do
    if letter == ?B or byte_size(packet) == Map.fetch!(@other_packets, letter),
      do: :ignore,
      else: :not_a_packet
  end

  def parse(_data), do: :not_a_packet

  @doc "The checksum Bluefruit Connect appends: `~sum(bytes)`, low byte."
  @spec checksum(binary()) :: byte()
  def checksum(bytes) do
    sum = for <<byte <- bytes>>, reduce: 0, do: (acc -> acc + byte)
    Bitwise.band(Bitwise.bnot(sum), 0xFF)
  end

  @doc "Build a button packet, as Bluefruit Connect sends it."
  @spec packet(event()) :: binary()
  def packet({action, button}) do
    {char, ^button} = Enum.find(@buttons, fn {_char, b} -> b == button end)
    body = <<"!B", char, if(action == :pressed, do: ?1, else: ?0)>>
    body <> <<checksum(body)>>
  end

  @doc "Track a direction button. The numbered buttons don't change the pad."
  @spec apply_event(t(), event()) :: t()
  def apply_event(%__MODULE__{held: held} = pad, {:pressed, button}) when is_atom(button),
    do: %{pad | held: MapSet.put(held, button)}

  def apply_event(%__MODULE__{held: held} = pad, {:released, button}) when is_atom(button),
    do: %{pad | held: MapSet.delete(held, button)}

  def apply_event(pad, _event), do: pad

  @doc """
  The held buttons as `{throttle, steering}`, each `-1.0`, `0.0` or `1.0`.
  Opposite buttons held together cancel out.
  """
  @spec drive(t()) :: {float(), float()}
  def drive(%__MODULE__{held: held}) do
    {axis(held, :up, :down), axis(held, :right, :left)}
  end

  @doc "Whether no direction is held."
  @spec released?(t()) :: boolean()
  def released?(%__MODULE__{held: held}), do: MapSet.size(held) == 0

  defp axis(held, positive, negative) do
    case {MapSet.member?(held, positive), MapSet.member?(held, negative)} do
      {true, false} -> 1.0
      {false, true} -> -1.0
      _ -> 0.0
    end
  end
end
