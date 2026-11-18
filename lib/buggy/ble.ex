defmodule Buggy.BLE do
  @moduledoc """
  The buggy over Bluetooth LE, as a GATT peripheral named `buggy-<serial>`
  (the last four characters of the serial number, as in the hostname).

  Two services, each matching a scheme existing clients already speak:

    * **Improv Wi-Fi** (`Buggy.BLE.Improv`): give the car a Wi-Fi network
      from https://www.improv-wifi.com/ in Chrome, Home Assistant, or
      anything else that provisions ESPHome devices. On success the car is on
      the new network, saved for later boots; on failure it goes back to the
      old one.

    * **Nordic UART Service**, the usual serial-over-BLE for hobby robots,
      carrying two things:
        * Adafruit Bluefruit Connect's Control Pad (`Buggy.BLE.ControlPad`):
          hold the arrows to drive (up/down throttle, capped by
          `limits.max_throttle`, left/right full lock), 1 arms, 2 disarms.
        * A text console (`Buggy.BLE.Console`) for robot commands,
          parameters (list, get, set, unset) and Wi-Fi, from Bluefruit
          Connect's UART screen or any BLE serial terminal.

  ## Driving safety

  The Control Pad only sends presses and releases, so while an arrow is held
  the throttle is renewed every 100 ms for 300 ms at a time, and it
  stops when:

    * the arrow is released,
    * the connection drops (as soon as the radio notices: up to the link's
      supervision timeout, which is asked to be 2 s),
    * the robot stops being `:idle` (disarmed, or running a command), or
    * no button has changed for 10 s, in case the app went to the
      background with an arrow held.

  Anyone in radio range can connect: there is no pairing.

  ## Processes

  BlueHeron runs as a temporary application, so if it fails the rest of the
  car carries on, and this process attaches to it again. Its GATT callbacks
  only read an ETS table owned here or send messages, as they run inside
  BlueHeron while this process may be calling it. Console lines, Wi-Fi joins
  and robot commands run in their own processes, so driving never waits for
  them.
  """
  use GenServer

  import Bitwise

  require Logger

  alias Buggy.BLE.{Advertising, Console, ControlPad, Improv}
  alias Buggy.Drive

  @uart_service 0x6E400001_B5A3_F393_E0A9_E50E24DCCA9E
  @uart_rx 0x6E400002_B5A3_F393_E0A9_E50E24DCCA9E
  @uart_tx 0x6E400003_B5A3_F393_E0A9_E50E24DCCA9E

  @read 0x02
  @write 0x08
  @notify 0x10
  @indicate 0x20

  # BlueHeron's ATT MTU of 23, less a notification's 3-byte header.
  @notification_bytes 20

  @drive_tick_ms 100
  @throttle_ms 300
  @max_hold_ms 10_000

  # Bluefruit Connect sends a line without an end-of-line unless told to, in
  # writes of up to 20 bytes, so a line also ends when the writes pause.
  @line_pause_ms 300
  @max_line_bytes 512

  @attach_retry_ms 5_000
  # Interval 15-30 ms, no latency, 2 s supervision timeout: within what iOS
  # and Android accept. Only asked for if the central chose a longer timeout.
  @connection_parameters [interval_min: 12, interval_max: 24, latency: 0, timeout: 200]
  @connection_parameters_delay_ms 1_000

  @type option ::
          {:name, GenServer.name()}
          | {:robot, module()}
          | {:stack, module()}
          | {:device_name, String.t()}
          | {:wifi, keyword()}
          | {:max_hold_ms, pos_integer()}

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 5_000}
  end

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The GATT services, as `Buggy.BLE.Stack` describes them."
  @spec services() :: [Buggy.BLE.Stack.service()]
  def services do
    [
      %{
        id: :gap,
        uuid: 0x1800,
        characteristics: [
          %{id: :device_name, uuid: 0x2A00, properties: @read},
          %{id: :appearance, uuid: 0x2A01, properties: @read}
        ]
      },
      %{
        id: :gatt,
        uuid: 0x1801,
        characteristics: [
          %{id: :service_changed, uuid: 0x2A05, properties: @indicate, cccd: true}
        ]
      },
      %{
        id: :improv,
        uuid: Improv.service_uuid(),
        characteristics: [
          %{
            id: :improv_state,
            uuid: Improv.current_state_uuid(),
            properties: @read ||| @notify,
            cccd: true
          },
          %{
            id: :improv_error,
            uuid: Improv.error_state_uuid(),
            properties: @read ||| @notify,
            cccd: true
          },
          %{id: :improv_rpc, uuid: Improv.rpc_command_uuid(), properties: @write},
          %{
            id: :improv_result,
            uuid: Improv.rpc_result_uuid(),
            properties: @read ||| @notify,
            cccd: true
          },
          %{id: :improv_capabilities, uuid: Improv.capabilities_uuid(), properties: @read}
        ]
      },
      %{
        id: :uart,
        uuid: @uart_service,
        characteristics: [
          %{id: :uart_rx, uuid: @uart_rx, properties: @write},
          %{id: :uart_tx, uuid: @uart_tx, properties: @notify, cccd: true}
        ]
      }
    ]
  end

  @doc "The Nordic UART Service's UUID."
  def uart_service_uuid, do: @uart_service

  ## GATT callbacks, called from inside the stack

  @doc "A characteristic's current value. Never blocks on `Buggy.BLE`."
  @spec gatt_read(:ets.tid(), atom()) :: binary()
  def gatt_read(table, characteristic) do
    case :ets.lookup(table, characteristic) do
      [{^characteristic, value}] -> value
      [] -> <<>>
    end
  rescue
    # The table went with a Buggy.BLE that's restarting.
    ArgumentError -> <<>>
  end

  @doc "A central wrote `value`. Always `:ok`, which BlueHeron insists on."
  @spec gatt_write(pid(), atom(), binary()) :: :ok
  def gatt_write(server, characteristic, value) do
    send(server, {:gatt_write, characteristic, value})
    :ok
  end

  @doc "A central turned notifications on or off."
  @spec gatt_subscribe(pid(), atom(), boolean()) :: :ok
  def gatt_subscribe(server, characteristic, on?) do
    send(server, {:gatt_subscribe, characteristic, on?})
    :ok
  end

  ## Server

  defstruct [
    :robot,
    :stack,
    :name,
    :table,
    :wifi,
    :max_hold_ms,
    attached?: false,
    attach_failures: 0,
    connection: nil,
    subscribed: MapSet.new(),
    improv_rx: <<>>,
    uart_rx: <<>>,
    line_timer: nil,
    lines: :queue.new(),
    console: nil,
    jobs: %{},
    wifi_join: nil,
    pad: %ControlPad{},
    pad_changed_at: 0,
    applied: nil,
    drive_timer: nil
  ]

  @impl GenServer
  def init(opts) do
    # BlueHeron's registry links to subscribers; its exit arrives as a message.
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      robot: Keyword.get(opts, :robot, Buggy.Robot),
      stack: Keyword.get(opts, :stack, Buggy.BLE.BlueHeronStack),
      name: Keyword.get_lazy(opts, :device_name, &default_name/0),
      table: :ets.new(__MODULE__, [:protected, read_concurrency: true]),
      wifi: Keyword.get(opts, :wifi, []),
      max_hold_ms: Keyword.get(opts, :max_hold_ms, @max_hold_ms)
    }

    :ets.insert(state.table, [
      {:device_name, state.name},
      # Unknown: there's no appearance for a car.
      {:appearance, <<0::little-16>>},
      {:service_changed, <<>>},
      {:improv_state, <<Improv.authorized()>>},
      {:improv_error, <<Improv.error(:none)>>},
      {:improv_capabilities, <<0>>},
      {:improv_result, <<>>}
    ])

    send(self(), :attach)
    {:ok, state}
  end

  defp default_name do
    serial = Nerves.Runtime.serial_number()
    "buggy-" <> String.slice(serial, -4..-1//1)
  end

  @impl GenServer
  def handle_info(:attach, state) do
    case state.stack.attach(self(), state.table, services()) do
      {:ok, ready?} ->
        if state.attach_failures > 0, do: Logger.info("BLE is available again")
        state = %{state | attached?: true, attach_failures: 0}
        if ready?, do: advertise(state)
        {:noreply, state}

      {:error, reason} ->
        # Once, rather than every few seconds on a car without a radio.
        if state.attach_failures == 0,
          do: Logger.warning("BLE isn't available, retrying: #{inspect(reason, limit: 5)}")

        Process.send_after(self(), :attach, @attach_retry_ms)
        {:noreply, %{state | attach_failures: state.attach_failures + 1}}
    end
  end

  # A port closing, like System.cmd's when reading the serial number: trapping
  # exits turns its link into a message too.
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  def handle_info({:EXIT, _pid, reason}, state) do
    # The stack's registry went down: BlueHeron stopped, or is restarting.
    Logger.warning("BLE stack stopped (#{inspect(reason, limit: 5)}), reattaching")
    Process.send_after(self(), :attach, 1_000)
    {:noreply, %{disconnected(state) | attached?: false}}
  end

  def handle_info({:gatt_write, :improv_rpc, data}, state) do
    {:noreply, improv_rpc(%{state | improv_rx: state.improv_rx <> data})}
  end

  def handle_info({:gatt_write, :uart_rx, data}, state) do
    case ControlPad.parse(data) do
      {:ok, event} -> {:noreply, pad_event(state, event)}
      :ignore -> {:noreply, state}
      :not_a_packet -> {:noreply, uart_text(state, data)}
    end
  end

  def handle_info({:gatt_write, _characteristic, _data}, state), do: {:noreply, state}

  def handle_info({:gatt_subscribe, characteristic, true}, state) do
    state = %{state | subscribed: MapSet.put(state.subscribed, characteristic)}

    if characteristic == :uart_tx do
      robot_state = Console.robot_state(state.robot)
      {:noreply, uart_send(state, "#{state.name}: #{robot_state}. Type help.\n")}
    else
      {:noreply, state}
    end
  end

  def handle_info({:gatt_subscribe, characteristic, false}, state) do
    {:noreply, %{state | subscribed: MapSet.delete(state.subscribed, characteristic)}}
  end

  def handle_info({:line_pause, timer}, %{line_timer: timer} = state) do
    line = state.uart_rx
    {:noreply, %{state | uart_rx: <<>>, line_timer: nil} |> enqueue_line(line)}
  end

  def handle_info({:line_pause, _stale}, state), do: {:noreply, state}

  def handle_info(:drive_tick, state), do: {:noreply, drive_tick(%{state | drive_timer: nil})}

  def handle_info({:connection_parameters, handle}, %{connection: handle} = state) do
    _ = state.stack.request_connection_parameters(handle, @connection_parameters)
    {:noreply, state}
  end

  def handle_info({:connection_parameters, _handle}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.jobs, ref) do
      {nil, _jobs} -> {:noreply, state}
      {kind, jobs} -> {:noreply, job_done(%{state | jobs: jobs}, kind, reason)}
    end
  end

  def handle_info(message, state) do
    case state.stack.event(message) do
      :ignore -> {:noreply, state}
      event -> {:noreply, stack_event(state, event)}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    _ = stop_driving(state)
    :ok
  end

  ## Stack events

  # The radio came up, or came back after its transport restarted, which
  # dropped any connection without a word.
  defp stack_event(state, :ready) do
    advertise(state)
    disconnected(state)
  end

  defp stack_event(state, {:connected, handle, info}) do
    Logger.info("BLE central connected (connection #{handle})")

    if (info[:supervision_timeout] || 0) > @connection_parameters[:timeout] do
      Process.send_after(
        self(),
        {:connection_parameters, handle},
        @connection_parameters_delay_ms
      )
    end

    %{disconnected(state) | connection: handle}
  end

  defp stack_event(state, {:disconnected, handle, reason}) do
    Logger.info("BLE central disconnected (connection #{handle}): #{inspect(reason)}")
    disconnected(state)
  end

  # Whatever the last central was doing ends with it. A Wi-Fi join carries on,
  # and the Improv state reads "provisioning" until it's done.
  defp disconnected(state) do
    state = stop_driving(state)

    improv_state =
      if state.wifi_join, do: Improv.provisioning(), else: Improv.authorized()

    :ets.insert(state.table, {:improv_state, <<improv_state>>})

    %{
      state
      | connection: nil,
        subscribed: MapSet.new(),
        improv_rx: <<>>,
        uart_rx: <<>>,
        line_timer: nil,
        lines: :queue.new()
    }
  end

  defp advertise(state) do
    advertising_data = Advertising.advertising_data(Improv.authorized())
    scan_response = Advertising.scan_response(state.name, @uart_service)

    case state.stack.advertise(advertising_data, scan_response) do
      :ok -> Logger.info("Advertising over BLE as #{state.name}")
      {:error, reason} -> Logger.warning("BLE advertising failed: #{inspect(reason, limit: 5)}")
    end
  end

  ## Improv

  defp improv_rpc(state) do
    case Improv.take_command(state.improv_rx) do
      :incomplete ->
        state

      {:error, :invalid_rpc, rest} ->
        improv_error(%{state | improv_rx: rest}, :invalid_rpc)

      {:ok, command, data, rest} ->
        state = improv_command(%{state | improv_rx: rest}, command, data)
        if rest == <<>>, do: state, else: improv_rpc(state)
    end
  end

  defp improv_command(state, command, data) do
    cond do
      command != Improv.send_wifi_settings() ->
        improv_error(state, :unknown_command)

      state.wifi_join != nil ->
        improv_error(state, :unknown)

      true ->
        case Improv.decode_wifi_settings(data) do
          {:ok, ssid, password} ->
            state
            |> improv_error(:none)
            |> improv_state(Improv.provisioning())
            |> start_wifi_join(:improv, ssid, password)

          :error ->
            improv_error(state, :invalid_rpc)
        end
    end
  end

  defp improv_state(state, value), do: put_and_notify(state, :improv_state, <<value>>)
  defp improv_error(state, name), do: put_and_notify(state, :improv_error, <<Improv.error(name)>>)

  defp put_and_notify(state, characteristic, value) do
    :ets.insert(state.table, {characteristic, value})
    notify(state, characteristic, value)
  end

  defp improv_wifi_result(state, {:ok, status}) do
    url = "http://#{status.address}"
    result = Improv.encode_result(Improv.send_wifi_settings(), [url])
    :ets.insert(state.table, {:improv_result, result})

    # The URL rarely fits in a notification; reading the characteristic gets
    # all of it.
    notification =
      if byte_size(result) <= @notification_bytes,
        do: result,
        else: Improv.encode_result(Improv.send_wifi_settings(), [])

    state
    |> improv_state(Improv.provisioned())
    |> notify(:improv_result, notification)
  end

  defp improv_wifi_result(state, {:error, _reason}) do
    state
    |> improv_error(:unable_to_connect)
    |> improv_state(Improv.authorized())
  end

  ## Wi-Fi

  defp start_wifi_join(state, origin, ssid, psk) do
    wifi = state.wifi
    job = spawn_job(fn -> Buggy.WiFi.join(ssid, psk, wifi) end)
    %{state | wifi_join: %{ssid: ssid, origin: origin}, jobs: Map.put(state.jobs, job, :wifi)}
  end

  defp wifi_done(state, result) do
    %{ssid: ssid, origin: origin} = state.wifi_join
    state = %{state | wifi_join: nil}

    case origin do
      :improv -> improv_wifi_result(state, result)
      :console -> uart_send(state, wifi_message(ssid, result))
    end
  end

  defp wifi_message(ssid, {:ok, status}), do: "wifi: joined #{ssid}, #{status.address}\n"

  defp wifi_message(ssid, {:error, :unable_to_connect}),
    do: "wifi: couldn't join #{ssid}, back on the previous network\n"

  defp wifi_message(ssid, {:error, reason}),
    do: "wifi: #{ssid} failed: #{inspect(reason, limit: 5)}\n"

  ## Console

  defp uart_text(state, data) do
    {lines, rest} = split_lines(state.uart_rx <> data)
    # A new line_pause token makes any pending one stale.
    state = Enum.reduce(lines, %{state | uart_rx: <<>>, line_timer: nil}, &enqueue_line(&2, &1))

    cond do
      rest == <<>> ->
        state

      byte_size(rest) > @max_line_bytes ->
        uart_send(state, "error: line too long\n")

      true ->
        timer = make_ref()
        Process.send_after(self(), {:line_pause, timer}, @line_pause_ms)
        %{state | uart_rx: rest, line_timer: timer}
    end
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, ["\r\n", "\n", "\r"])
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp enqueue_line(state, line) do
    if String.trim(line) == "",
      do: state,
      else: run_next_line(%{state | lines: :queue.in(line, state.lines)})
  end

  defp run_next_line(%{console: nil} = state) do
    case :queue.out(state.lines) do
      {:empty, _lines} ->
        state

      {{:value, line}, lines} ->
        %{robot: robot, wifi: wifi} = state
        job = spawn_job(fn -> Console.run(line, robot, wifi) end)
        %{state | lines: lines, console: job, jobs: Map.put(state.jobs, job, :console)}
    end
  end

  defp run_next_line(state), do: state

  defp console_actions(state, actions) do
    Enum.reduce(actions, state, fn
      {:reply, text}, state ->
        uart_send(state, text)

      {:await, pid, name}, state ->
        job = spawn_job(fn -> Console.await(pid, name) end)
        %{state | jobs: Map.put(state.jobs, job, :await)}

      {:wifi_join, ssid, _psk}, %{wifi_join: %{ssid: joining}} = state ->
        uart_send(state, "wifi: already joining #{joining} (not #{ssid})\n")

      {:wifi_join, ssid, psk}, state ->
        start_wifi_join(state, :console, ssid, psk)
    end)
  end

  ## Jobs: plain processes that report by exiting with their result

  defp spawn_job(fun) do
    {_pid, ref} = spawn_monitor(fn -> exit({:result, fun.()}) end)
    ref
  end

  defp job_done(state, kind, reason) do
    result =
      case reason do
        {:result, result} -> {:ok, result}
        other -> {:crashed, other}
      end

    case {kind, result} do
      {:wifi, {:ok, result}} ->
        wifi_done(state, result)

      {:wifi, {:crashed, reason}} ->
        wifi_done(state, {:error, reason})

      {:console, {:ok, actions}} ->
        state = %{state | console: nil}
        state |> console_actions(actions) |> run_next_line()

      {:console, {:crashed, reason}} ->
        Logger.warning("BLE console line crashed: #{inspect(reason, limit: 5)}")
        state = %{state | console: nil}
        state |> uart_send("error: #{inspect(reason, limit: 3)}\n") |> run_next_line()

      {:pad, {:ok, actions}} ->
        console_actions(state, actions)

      {:await, {:ok, text}} ->
        uart_send(state, text)

      {_kind, {:crashed, reason}} ->
        uart_send(state, "error: #{inspect(reason, limit: 3)}\n")
    end
  end

  ## Control Pad

  defp pad_event(state, {:pressed, 1}), do: pad_command(state, "arm")
  defp pad_event(state, {:pressed, 2}), do: state |> stop_driving() |> pad_command("disarm")

  defp pad_event(state, {:pressed, n}) when n in 3..4,
    do: uart_send(state, "button #{n} does nothing\n")

  defp pad_event(state, {:released, n}) when is_integer(n), do: state

  defp pad_event(state, event) do
    state = %{
      state
      | pad: ControlPad.apply_event(state.pad, event),
        pad_changed_at: now()
    }

    if ControlPad.released?(state.pad) do
      stop_driving(state)
    else
      case Console.robot_state(state.robot) do
        :idle ->
          {throttle, steering} = ControlPad.drive(state.pad)
          drive(state, throttle, steering)

        robot_state ->
          state
          |> stop_driving()
          |> uart_send("not driving: the robot is #{robot_state}, press 1 to arm\n")
      end
    end
  end

  defp pad_command(state, line) do
    %{robot: robot, wifi: wifi} = state
    job = spawn_job(fn -> Console.run(line, robot, wifi) end)
    %{state | jobs: Map.put(state.jobs, job, :pad)}
  end

  defp drive(state, throttle, steering) do
    {last_throttle, last_steering} = state.applied || {0.0, nil}

    result =
      with :ok <- steer(state.robot, steering, last_steering) do
        throttle(state.robot, throttle, last_throttle)
      end

    case result do
      :ok ->
        state = %{state | applied: {throttle, steering}}

        if throttle != 0.0 and state.drive_timer == nil,
          do: %{state | drive_timer: Process.send_after(self(), :drive_tick, @drive_tick_ms)},
          else: state

      {:error, reason} ->
        Logger.warning("BLE driving failed: #{inspect(reason, limit: 5)}")

        state
        |> stop_driving()
        |> uart_send("driving failed: #{inspect(reason, limit: 3)}\n")
    end
  end

  defp steer(_robot, steering, steering), do: :ok
  defp steer(robot, steering, _last), do: safely(fn -> Drive.steer(steering, robot) end)

  defp throttle(_robot, +0.0, +0.0), do: :ok
  defp throttle(robot, +0.0, _last), do: safely(fn -> Drive.stop_throttle(robot) end)

  defp throttle(robot, throttle, _last),
    do: safely(fn -> Drive.throttle(throttle, @throttle_ms, robot) end)

  # While an arrow is held, renew the throttle before it runs out.
  defp drive_tick(%{applied: {throttle, _steering}} = state) when throttle != 0.0 do
    cond do
      now() - state.pad_changed_at >= state.max_hold_ms ->
        state
        |> stop_driving()
        |> uart_send("stopped: held #{div(state.max_hold_ms, 1000)} s without a change\n")

      Console.robot_state(state.robot) != :idle ->
        stop_driving(state)

      true ->
        case throttle(state.robot, throttle, nil) do
          :ok ->
            %{state | drive_timer: Process.send_after(self(), :drive_tick, @drive_tick_ms)}

          {:error, _reason} ->
            stop_driving(state)
        end
    end
  end

  defp drive_tick(state), do: state

  # Neutral and straight ahead, if the pad drove anything; and forget the pad.
  defp stop_driving(state) do
    if state.drive_timer, do: Process.cancel_timer(state.drive_timer)
    if state.applied, do: safely(fn -> Drive.stop(state.robot) end)
    %{state | applied: nil, drive_timer: nil, pad: %ControlPad{}}
  end

  # The robot can be restarting, with its processes and tables gone.
  defp safely(fun) do
    case fun.() do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, _} = error -> error
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  ## Notifications

  defp uart_send(state, text) do
    text
    |> chunks(@notification_bytes)
    |> Enum.reduce(state, &notify(&2, :uart_tx, &1))
  end

  # Split at character boundaries, so each notification is valid UTF-8.
  defp chunks(text, size) do
    text
    |> String.graphemes()
    |> Enum.chunk_while(
      "",
      fn g, acc ->
        if byte_size(acc) + byte_size(g) > size, do: {:cont, acc, g}, else: {:cont, acc <> g}
      end,
      fn
        "" -> {:cont, ""}
        acc -> {:cont, acc, ""}
      end
    )
    |> Enum.reject(&(&1 == ""))
  end

  defp notify(state, characteristic, value) do
    if MapSet.member?(state.subscribed, characteristic) do
      case state.stack.notify(service_of(characteristic), characteristic, value) do
        :ok -> :ok
        {:error, reason} -> Logger.debug("BLE notify failed: #{inspect(reason)}")
      end
    end

    state
  end

  defp service_of(:uart_tx), do: :uart
  defp service_of(_improv), do: :improv

  defp now, do: System.monotonic_time(:millisecond)
end
