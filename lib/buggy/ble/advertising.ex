defmodule Buggy.BLE.Advertising do
  @moduledoc """
  The advertisement and scan response, each at most 31 bytes.

  The advertisement is what Improv requires in one packet (its service UUID
  and its state as service data) after the flags: 3 + 18 + 10 = 31 bytes,
  exactly full. The scan response carries the name and the Nordic UART
  Service's UUID, which is how Bluefruit Connect and nRF Toolbox spot a UART
  device; the name is shortened if it doesn't fit beside it.
  """

  alias Buggy.BLE.Improv

  @max 31

  # LE General Discoverable, BR/EDR not supported.
  @flags <<2, 0x01, 0x06>>

  @complete_128 0x07
  @incomplete_128 0x06
  @service_data_16 0x16
  @shortened_name 0x08
  @complete_name 0x09

  @doc "The advertisement: flags, Improv's service UUID and its state."
  @spec advertising_data(byte()) :: binary()
  def advertising_data(improv_state) do
    service_data =
      <<Improv.service_data_uuid()::little-16>> <> Improv.service_data(improv_state, 0)

    @flags <>
      ad(@complete_128, <<Improv.service_uuid()::little-128>>) <>
      ad(@service_data_16, service_data)
  end

  @doc "The scan response: the name, then the UART service's UUID."
  @spec scan_response(String.t(), pos_integer()) :: binary()
  def scan_response(name, uart_uuid) do
    uuids = ad(@incomplete_128, <<uart_uuid::little-128>>)
    room = @max - byte_size(uuids) - 2

    name_ad =
      if byte_size(name) <= room,
        do: ad(@complete_name, name),
        else: ad(@shortened_name, truncate(name, room))

    name_ad <> uuids
  end

  defp ad(type, data), do: <<byte_size(data) + 1, type, data::binary>>

  # Cut at a character boundary.
  defp truncate(name, bytes) do
    name
    |> String.graphemes()
    |> Enum.reduce_while("", fn g, acc ->
      if byte_size(acc <> g) <= bytes, do: {:cont, acc <> g}, else: {:halt, acc}
    end)
  end
end
