defmodule Buggy.Test.StubPWM do
  @moduledoc false
  # Records every pulse width written, standing in for the PCA9685.
  use BB.Controller

  @impl BB.Controller
  def init(_opts), do: {:ok, %{}}

  @impl BB.Controller
  def handle_call({:pulse_width, channel, us}, _from, state) do
    if pid = Process.whereis(:buggy_test_listener), do: send(pid, {:pulse, channel, us})
    {:reply, :ok, state}
  end
end

defmodule Buggy.Test.Robot do
  @moduledoc false
  # Buggy.Robot's commands, drive joints and parameters, on the stub PWM:
  # steering on channel 1 (1800 µs full left, 1200 full right), the ESC on 0
  # (1500 neutral, full throttle capped at 0.3, so 1650 forward, 1350 back).
  use BB

  commands do
    command :arm do
      handler(BB.Command.Arm)
      allowed_states([:disarmed])
    end

    command :disarm do
      handler(BB.Command.Disarm)
      allowed_states([:idle])
      cancel([:default])
    end

    command :steer do
      handler(Buggy.Commands.Steer)
      allowed_states([:idle])
      cancel([:default])
      argument(:steering, :float, default: 0.0)
    end

    command :throttle do
      handler(Buggy.Commands.Throttle)
      allowed_states([:idle])
      cancel([:default])
      argument(:throttle, :float, default: 0.2)
      argument(:duration_ms, :integer, default: 1000)
    end

    command :stop do
      handler(Buggy.Commands.Stop)
      allowed_states([:idle])
      cancel([:default])
    end
  end

  topology do
    link :base_link do
      joint :steering do
        type(:revolute)

        limit do
          lower(~u(-25 degree))
          upper(~u(25 degree))
          effort(~u(1 newton_meter))
          velocity(~u(300 degree_per_second))
        end

        actuator(
          :steering_servo,
          {BB.Servo.PCA9685.Actuator,
           channel: 1, controller: :pwm, min_pulse: 1200, max_pulse: 1800}
        )

        sensor(
          :steering_feedback,
          {BB.Sensor.OpenLoopPositionEstimator, actuator: :steering_servo}
        )

        link :steering_input do
        end
      end

      joint :drive do
        type(:continuous)

        limit do
          effort(~u(1 newton_meter))
          velocity(~u(3600 degree_per_second))
        end

        actuator(
          :esc,
          {Buggy.Actuator.ESC,
           channel: 0,
           controller: :pwm,
           neutral_pulse: param([:calibration, :esc_neutral_pulse]),
           max_throttle: param([:limits, :max_throttle])}
        )

        link :rear_axle do
        end
      end
    end
  end

  controllers do
    controller(:pwm, Buggy.Test.StubPWM)
  end

  parameters do
    group :limits do
      param(:max_throttle,
        type: :float,
        default: 0.3,
        min: 0.0,
        max: 1.0,
        doc: "Cap on throttle magnitude"
      )
    end

    group :calibration do
      param(:esc_neutral_pulse, type: :integer, default: 1500, min: 1300, max: 1700)
    end

    group :video do
      param(:resolution, type: :string, default: "640x480")
      param(:rotate_180, type: :boolean, default: false)
    end

    group :config do
      param(:address, type: :integer, default: 0x40)
    end
  end
end

defmodule Buggy.Test.FakeVintageNet do
  @moduledoc false
  # wlan0 as far as Buggy.WiFi can tell, behaving like the car's: no
  # current_ap; an unchanged configuration is left alone; a changed one still
  # reports the old connection for a moment, then disconnected, then (if the
  # network's in `reachable`, SSID => PSK with "" for open, with that PSK)
  # connected. Subscribers get VintageNet's change messages.
  use GenServer

  @connection ["interface", "wlan0", "connection"]
  @teardown_ms 10
  @connect_ms 30

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def configured, do: GenServer.call(__MODULE__, :configured)
  def get_configuration("wlan0"), do: GenServer.call(__MODULE__, :config)
  def configure("wlan0", config), do: GenServer.call(__MODULE__, {:configure, config})
  def get(property), do: GenServer.call(__MODULE__, {:get, property})
  def subscribe(@connection), do: GenServer.call(__MODULE__, {:subscribe, self()})
  def unsubscribe(@connection), do: GenServer.call(__MODULE__, {:unsubscribe, self()})

  @impl true
  def init(opts) do
    config = Buggy.WiFi.config(Keyword.fetch!(opts, :ssid), Keyword.fetch!(opts, :psk))
    state = %{config: config, reachable: Keyword.fetch!(opts, :reachable), configured: []}
    {:ok, Map.merge(state, %{connection: connection(state), subscribers: MapSet.new()})}
  end

  @impl true
  def handle_call(:configured, _from, state), do: {:reply, Enum.reverse(state.configured), state}
  def handle_call(:config, _from, state), do: {:reply, state.config, state}

  def handle_call({:configure, %{vintage_net_wifi: %{networks: [%{psk: psk}]}}}, _from, state)
      when byte_size(psk) < 8,
      do: {:reply, {:error, :bad_psk}, state}

  def handle_call({:configure, config}, _from, %{config: config} = state),
    do: {:reply, :ok, state}

  def handle_call({:configure, config}, _from, state) do
    Process.send_after(self(), {:set_connection, :disconnected}, @teardown_ms)
    Process.send_after(self(), :connect, @connect_ms)
    {:reply, :ok, %{state | config: config, configured: [config | state.configured]}}
  end

  def handle_call({:get, @connection}, _from, state), do: {:reply, state.connection, state}

  def handle_call({:get, ["interface", "wlan0", "addresses"]}, _from, state) do
    addresses =
      if state.connection == :internet, do: [%{family: :inet, address: {10, 0, 0, 7}}], else: []

    {:reply, addresses, state}
  end

  def handle_call({:get, _property}, _from, state), do: {:reply, nil, state}

  def handle_call({:subscribe, pid}, _from, state),
    do: {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}

  def handle_call({:unsubscribe, pid}, _from, state),
    do: {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}

  @impl true
  def handle_info(:connect, state), do: handle_info({:set_connection, connection(state)}, state)

  def handle_info({:set_connection, new}, %{connection: old} = state) do
    if new != old,
      do: for(pid <- state.subscribers, do: send(pid, {VintageNet, @connection, old, new, %{}}))

    {:noreply, %{state | connection: new}}
  end

  defp connection(%{config: config, reachable: reachable}) do
    [network] = config.vintage_net_wifi.networks

    if Map.get(reachable, network.ssid) == Map.get(network, :psk, ""),
      do: :internet,
      else: :disconnected
  end
end

defmodule Buggy.Test.FakeStack do
  @moduledoc false
  # Buggy.BLE.Stack, telling the test what Buggy.BLE asks of it. Tests send
  # Buggy.BLE `{:fake_stack, event}` for the stack's events.
  @behaviour Buggy.BLE.Stack

  @impl true
  def attach(server, table, services) do
    tell({:attached, server, table, services})
    {:ok, true}
  end

  @impl true
  def advertise(advertising_data, scan_response) do
    tell({:advertised, advertising_data, scan_response})
    :ok
  end

  @impl true
  def notify(_service, characteristic, data) do
    tell({:notified, characteristic, data})
    :ok
  end

  @impl true
  def request_connection_parameters(handle, params) do
    tell({:connection_parameters, handle, params})
    :ok
  end

  @impl true
  def event({:fake_stack, event}), do: event
  def event(_message), do: :ignore

  defp tell(message) do
    if pid = Process.whereis(:buggy_test_listener), do: send(pid, message)
  end
end
