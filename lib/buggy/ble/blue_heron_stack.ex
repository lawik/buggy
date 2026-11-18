defmodule Buggy.BLE.BlueHeronStack do
  @moduledoc """
  `Buggy.BLE.Stack` on BlueHeron, the Elixir BLE host that talks HCI to the
  Pi 3's radio over `/dev/ttyS0` (see `config :blue_heron` in target.exs).

  BlueHeron 0.5.4's quirks, which `Buggy.BLE` is built around:

    * Its GATT server answers every MTU exchange with 23, so a notification
      carries at most 20 bytes. Long reads and long (prepared) writes work.
    * It ignores Write Without Response, so writable characteristics only
      offer Write, which clients then use.
    * A GATT callback runs in its Peripheral process and must return `:ok`
      from a write, or the Peripheral crashes.
    * Its HCI transport crashes if two processes send it commands at once.
      Only the advertising setup sends any from here, at start-up and after
      the transport restarts, when nothing else is.
  """
  @behaviour Buggy.BLE.Stack

  alias BlueHeron.{ACL, Broadcaster, L2Cap, Peripheral}
  alias BlueHeron.GATT.{Characteristic, Service}
  alias BlueHeron.GATT.Characteristic.Descriptor
  alias BlueHeron.HCI.Event.{DisconnectionComplete, LEMeta}
  alias BlueHeron.HCI.Transport

  # Advertise every 152.5 ms (in 0.625 ms units), as Apple recommends.
  @advertising_interval 244

  # L2CAP LE signalling channel, and its Connection Parameter Update Request.
  @signalling_cid 0x0005
  @connection_parameter_update_request 0x12

  @impl Buggy.BLE.Stack
  def attach(server, table, services) do
    # A temporary application (see release/0 in mix.exs), so start it again
    # if it stopped.
    with {:ok, _apps} <- Application.ensure_all_started(:blue_heron, :temporary),
         :ok <- subscribe() do
      # add_service/1 prepends, so going backwards leaves them in order.
      for service <- Enum.reverse(services) do
        :ok = Peripheral.delete_service(service.id)
        :ok = Peripheral.add_service(build(service, server, table))
      end

      {:ok, Transport.setup_complete?()}
    end
  rescue
    # BlueHeron's processes aren't running (yet).
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  # Registry.register/3 would subscribe a second time on a retry.
  defp subscribe do
    if Registry.keys(BlueHeron.Registry, self()) == [],
      do: BlueHeron.Registry.subscribe(),
      else: :ok
  end

  defp build(service, server, table) do
    Service.new(%{
      id: service.id,
      type: service.uuid,
      characteristics: Enum.map(service.characteristics, &characteristic/1),
      read: &Buggy.BLE.gatt_read(table, &1),
      write: &Buggy.BLE.gatt_write(server, &1, &2),
      subscribe: &Buggy.BLE.gatt_subscribe(server, &1, true),
      unsubscribe: &Buggy.BLE.gatt_subscribe(server, &1, false)
    })
  end

  defp characteristic(spec) do
    Characteristic.new(%{
      id: spec.id,
      type: spec.uuid,
      properties: spec.properties,
      descriptor: if(spec[:cccd], do: Descriptor.new(%{permissions: 0}))
    })
  end

  @impl Buggy.BLE.Stack
  def advertise(advertising_data, scan_response) do
    # Parameters can't change while advertising.
    _ = Broadcaster.stop_advertising()

    with :ok <-
           Broadcaster.set_advertising_parameters(
             advertising_interval_min: @advertising_interval,
             advertising_interval_max: @advertising_interval
           ),
         :ok <- Broadcaster.set_advertising_data(advertising_data),
         :ok <- Broadcaster.set_scan_response_data(scan_response) do
      Broadcaster.start_advertising()
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @impl Buggy.BLE.Stack
  def notify(service, characteristic, data) do
    Peripheral.notify(service, characteristic, data)
  catch
    :exit, reason -> {:error, reason}
  end

  @impl Buggy.BLE.Stack
  def request_connection_parameters(handle, params) do
    request =
      <<@connection_parameter_update_request, 1, 8::little-16,
        Keyword.fetch!(params, :interval_min)::little-16,
        Keyword.fetch!(params, :interval_max)::little-16,
        Keyword.fetch!(params, :latency)::little-16, Keyword.fetch!(params, :timeout)::little-16>>

    Transport.buffer_acl(%ACL{
      handle: handle,
      flags: %{bc: 0, pb: 0},
      data: %L2Cap{cid: @signalling_cid, data: request}
    })
  end

  @impl Buggy.BLE.Stack
  def event({:BLUETOOTH_EVENT_STATE, :HCI_STATE_WORKING}), do: :ready

  def event({:HCI_EVENT_PACKET, %LEMeta.ConnectionComplete{status: 0} = event}),
    do: {:connected, event.connection_handle, %{supervision_timeout: event.supervision_timeout}}

  def event({:HCI_EVENT_PACKET, %LEMeta.EnhancedConnectionCompleteV1{status: 0} = event}),
    do: {:connected, event.connection_handle, %{supervision_timeout: event.supervision_timeout}}

  def event({:HCI_EVENT_PACKET, %DisconnectionComplete{} = event}),
    do: {:disconnected, event.connection_handle, event.reason_name || event.reason}

  def event(_message), do: :ignore
end
