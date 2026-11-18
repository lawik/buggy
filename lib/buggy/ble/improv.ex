defmodule Buggy.BLE.Improv do
  @moduledoc """
  The Improv Wi-Fi protocol over BLE (https://www.improv-wifi.com/ble/), an
  open standard for giving a device Wi-Fi credentials. ESPHome and WLED use
  it, Home Assistant discovers it, and https://www.improv-wifi.com/ provisions
  from Chrome through Web Bluetooth.

  The service has five characteristics:

    * current state (read, notify): `0x02` authorized, `0x03` provisioning
      (joining the network), `0x04` provisioned
    * error state (read, notify): `0x00` none, `0x01` invalid RPC packet,
      `0x02` unknown command, `0x03` unable to connect, `0xFF` unknown
    * RPC command (write): `command, length, data, checksum`, possibly over
      several writes, so it's reassembled until a whole packet is in
    * RPC result (read, notify): `command, length, strings, checksum`, each
      string length-prefixed
    * capabilities (read): a bitmask of the optional commands

  The checksum is the low byte of the sum of the bytes before it.

  Only "send Wi-Fi settings" is supported. BlueHeron keeps the ATT MTU at 23,
  so a notification carries at most 20 bytes, which is too few for device
  info or a scan's network list; capabilities is therefore `0`, and clients
  don't ask for them.
  """

  import Bitwise

  @service 0x00467768_6228_2272_4663_277478268000

  @doc "Service and characteristic UUIDs."
  def service_uuid, do: @service
  def current_state_uuid, do: @service + 1
  def error_state_uuid, do: @service + 2
  def rpc_command_uuid, do: @service + 3
  def rpc_result_uuid, do: @service + 4
  def capabilities_uuid, do: @service + 5

  @doc "16-bit UUID the state is advertised under, as service data."
  def service_data_uuid, do: 0x4677

  @authorized 0x02
  @provisioning 0x03
  @provisioned 0x04

  def authorized, do: @authorized
  def provisioning, do: @provisioning
  def provisioned, do: @provisioned

  @errors %{
    none: 0x00,
    invalid_rpc: 0x01,
    unknown_command: 0x02,
    unable_to_connect: 0x03,
    unknown: 0xFF
  }

  @doc "An error state's byte."
  @spec error(atom()) :: byte()
  def error(name), do: Map.fetch!(@errors, name)

  @send_wifi_settings 0x01

  @doc "The command byte for sending Wi-Fi settings."
  def send_wifi_settings, do: @send_wifi_settings

  # A command's length byte caps it at 255 data bytes.
  @max_packet 258

  @doc """
  Take one command off the front of the reassembly buffer.

  Returns `{:ok, command, data, rest}`, `:incomplete` while more writes are
  due, or `{:error, :invalid_rpc, rest}` for a bad checksum or a buffer too
  long to be a packet.
  """
  @spec take_command(binary()) ::
          {:ok, byte(), binary(), binary()} | :incomplete | {:error, :invalid_rpc, binary()}
  def take_command(<<command, length, data::binary-size(length), sum, rest::binary>>) do
    if checksum(<<command, length, data::binary>>) == sum,
      do: {:ok, command, data, rest},
      else: {:error, :invalid_rpc, <<>>}
  end

  def take_command(buffer) when byte_size(buffer) > @max_packet,
    do: {:error, :invalid_rpc, <<>>}

  def take_command(_buffer), do: :incomplete

  @doc "Decode the SSID and password of a send Wi-Fi settings command."
  @spec decode_wifi_settings(binary()) :: {:ok, String.t(), String.t()} | :error
  def decode_wifi_settings(
        <<ssid_length, ssid::binary-size(ssid_length), password_length,
          password::binary-size(password_length)>>
      )
      when ssid_length > 0 do
    if String.valid?(ssid) and String.valid?(password),
      do: {:ok, ssid, password},
      else: :error
  end

  def decode_wifi_settings(_data), do: :error

  @doc "Encode a command, as a client sends it."
  @spec encode_command(byte(), binary()) :: binary()
  def encode_command(command, data) do
    packet = <<command, byte_size(data), data::binary>>
    packet <> <<checksum(packet)>>
  end

  @doc "Encode Wi-Fi settings, as a client sends them."
  @spec encode_wifi_settings(String.t(), String.t()) :: binary()
  def encode_wifi_settings(ssid, password) do
    encode_command(
      @send_wifi_settings,
      <<byte_size(ssid), ssid::binary, byte_size(password), password::binary>>
    )
  end

  @doc "Encode an RPC result: the command it answers and a list of strings."
  @spec encode_result(byte(), [String.t()]) :: binary()
  def encode_result(command, strings) do
    data = for string <- strings, into: <<>>, do: <<byte_size(string), string::binary>>
    packet = <<command, byte_size(data), data::binary>>
    packet <> <<checksum(packet)>>
  end

  @doc """
  The 6 bytes advertised as service data: current state, capabilities and
  four reserved zeroes.
  """
  @spec service_data(byte(), byte()) :: binary()
  def service_data(state, capabilities), do: <<state, capabilities, 0, 0, 0, 0>>

  @doc "Low byte of the sum of `bytes`."
  @spec checksum(binary()) :: byte()
  def checksum(bytes) do
    sum = for <<byte <- bytes>>, reduce: 0, do: (acc -> acc + byte)
    sum &&& 0xFF
  end
end
