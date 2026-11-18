defmodule Buggy.BLE.Stack do
  @moduledoc """
  What `Buggy.BLE` needs from a BLE stack: `Buggy.BLE.BlueHeronStack` on the
  device, a stand-in in tests.

  Services are described as plain maps and the stack builds its own
  structures from them. Their characteristics' reads, writes and
  subscriptions go to `Buggy.BLE.gatt_read/2`, `gatt_write/3` and
  `gatt_subscribe/3`, which never block on `Buggy.BLE` itself, as the stack
  is often in the middle of a call from it.
  """

  @type handle :: non_neg_integer()

  @type characteristic :: %{
          required(:id) => atom(),
          required(:uuid) => pos_integer(),
          required(:properties) => byte(),
          optional(:cccd) => boolean()
        }

  @type service :: %{id: atom(), uuid: pos_integer(), characteristics: [characteristic()]}

  @type event ::
          :ready
          | {:connected, handle(), %{supervision_timeout: non_neg_integer() | nil}}
          | {:disconnected, handle(), term()}

  @doc """
  Start using the stack: subscribe the calling process to its events and
  register `services`. Returns whether the radio is ready to advertise; if
  not, `:ready` follows when it is.
  """
  @callback attach(server :: pid(), table :: :ets.tid(), [service()]) ::
              {:ok, ready? :: boolean()} | {:error, term()}

  @doc "Advertise, connectable, with this advertisement and scan response."
  @callback advertise(advertising_data :: binary(), scan_response :: binary()) ::
              :ok | {:error, term()}

  @doc "Notify the connected central of a characteristic's new value."
  @callback notify(service :: atom(), characteristic :: atom(), binary()) ::
              :ok | {:error, term()}

  @doc """
  Ask the central for new connection parameters: intervals in 1.25 ms
  units, the supervision timeout in 10 ms units.
  """
  @callback request_connection_parameters(handle(), keyword()) :: :ok | {:error, term()}

  @doc "Translate one of the stack's messages to the attached process."
  @callback event(message :: term()) :: event() | :ignore
end
