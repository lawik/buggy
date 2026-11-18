defmodule Buggy.BLETest do
  use ExUnit.Case, async: false

  alias Buggy.BLE.{ControlPad, Improv}
  alias Buggy.Test.{FakeStack, FakeVintageNet, Robot}

  setup do
    Process.register(self(), :buggy_test_listener)
    start_supervised!(Robot)
    # The ESC's neutral on start-up.
    assert_receive {:pulse, 0, 1500}

    start_supervised!(
      {FakeVintageNet,
       ssid: "Home", psk: "home-password", reachable: %{"Home" => "home-password", "Cafe" => ""}}
    )

    ble =
      start_supervised!(
        {Buggy.BLE,
         robot: Robot,
         stack: FakeStack,
         device_name: "buggy-test",
         wifi: [vintage_net: FakeVintageNet, timeout_ms: 200],
         max_hold_ms: 1_000}
      )

    assert_receive {:attached, ^ble, table, _services}
    assert_receive {:advertised, advertising_data, scan_response}
    send(ble, {:fake_stack, {:connected, 1, %{supervision_timeout: 100}}})

    %{ble: ble, table: table, advertising_data: advertising_data, scan_response: scan_response}
  end

  test "advertises Improv and the UART under its name, and serves reads", context do
    assert context.advertising_data == Buggy.BLE.Advertising.advertising_data(0x02)
    assert context.scan_response =~ "buggy-test"
    assert Buggy.BLE.gatt_read(context.table, :device_name) == "buggy-test"
    assert Buggy.BLE.gatt_read(context.table, :improv_state) == <<Improv.authorized()>>
    assert Buggy.BLE.gatt_read(context.table, :improv_capabilities) == <<0>>
  end

  describe "Improv" do
    setup %{ble: ble} do
      for c <- [:improv_state, :improv_error, :improv_result], do: subscribe(ble, c)
      :ok
    end

    test "provisions from settings written in 20-byte pieces", %{ble: ble, table: table} do
      for piece <- pieces(Improv.encode_wifi_settings("Cafe", ""), 20),
          do: write(ble, :improv_rpc, piece)

      assert_receive {:notified, :improv_error, <<0x00>>}
      assert_receive {:notified, :improv_state, <<0x03>>}
      assert_receive {:notified, :improv_state, <<0x04>>}, 1_000

      # "http://10.0.0.7" is short enough to notify whole.
      result = Improv.encode_result(0x01, ["http://10.0.0.7"])
      assert_receive {:notified, :improv_result, ^result}
      assert Buggy.BLE.gatt_read(table, :improv_result) == result
      assert FakeVintageNet.get_configuration("wlan0") == Buggy.WiFi.config("Cafe", "")

      # The next central can provision again.
      send(ble, {:fake_stack, {:disconnected, 1, :remote_user_terminated_connection}})
      _ = :sys.get_state(ble)
      assert Buggy.BLE.gatt_read(table, :improv_state) == <<0x02>>
    end

    test "a network that doesn't connect is an error, and the old one stays", %{ble: ble} do
      write(ble, :improv_rpc, Improv.encode_wifi_settings("Home", "wrong-password"))

      assert_receive {:notified, :improv_state, <<0x03>>}
      assert_receive {:notified, :improv_error, <<0x03>>}, 1_000
      assert_receive {:notified, :improv_state, <<0x02>>}

      assert FakeVintageNet.get_configuration("wlan0") ==
               Buggy.WiFi.config("Home", "home-password")
    end

    test "bad packets and unknown commands", %{ble: ble} do
      <<0x02, 0, sum>> = Improv.encode_command(0x02, "")
      write(ble, :improv_rpc, <<0x02, 0, sum + 1>>)
      assert_receive {:notified, :improv_error, <<0x01>>}

      write(ble, :improv_rpc, Improv.encode_command(0x02, ""))
      assert_receive {:notified, :improv_error, <<0x02>>}
    end
  end

  describe "console" do
    setup %{ble: ble} do
      subscribe(ble, :uart_tx)
      assert text() == "buggy-test: disarmed. Type help.\n"
      :ok
    end

    test "runs lines, in order, in notifications of at most 20 bytes", %{ble: ble} do
      write(ble, :uart_rx, "get limits.max_throttle\nset limits.max_throttle 0.25\n")
      assert text() =~ ~r/\Alimits.max_throttle = 0.3\n.*\nlimits.max_throttle = 0.25\n\z/s

      write(ble, :uart_rx, "help\r\n")
      assert text() =~ "wifi <ssid> [psk]"
    end

    test "a line without an end-of-line runs when the writes pause", %{ble: ble} do
      write(ble, :uart_rx, "params lim")
      write(ble, :uart_rx, "its")
      assert text(1_000) == "limits.max_throttle = 0.3\n"
    end

    test "joins Wi-Fi and says how it went", %{ble: ble} do
      write(ble, :uart_rx, "wifi Cafe\n")
      assert text(1_000) == "wifi: joining Cafe...\nwifi: joined Cafe, 10.0.0.7\n"
    end
  end

  describe "Control Pad" do
    setup %{ble: ble} do
      subscribe(ble, :uart_tx)
      _greeting = text()
      :ok
    end

    test "refuses to drive until armed", %{ble: ble} do
      pad(ble, {:pressed, :up})
      assert text() == "not driving: the robot is disarmed, press 1 to arm\n"
      refute_receive {:pulse, 0, 1650}
    end

    test "drives while held: throttle renewed, steering at full lock", %{ble: ble} do
      arm(ble)

      pad(ble, {:pressed, :up})
      assert_receive {:pulse, 0, 1650}
      pad(ble, {:pressed, :left})
      assert_receive {:pulse, 1, 1800}

      # Still going after several of the throttle's 300 ms runs.
      Process.sleep(450)
      flush_pulses()
      assert_receive {:pulse, 0, 1650}, 200

      pad(ble, {:released, :up})
      assert_receive {:pulse, 0, 1500}
      flush_pulses()
      refute_receive {:pulse, 0, 1650}, 400

      # Letting go of everything straightens up.
      pad(ble, {:released, :left})
      assert_receive {:pulse, 1, 1500}
    end

    test "reverses with down, and steers right", %{ble: ble} do
      arm(ble)
      pad(ble, {:pressed, :down})
      assert_receive {:pulse, 0, 1350}
      pad(ble, {:pressed, :right})
      assert_receive {:pulse, 1, 1200}
    end

    test "stops when the connection drops", %{ble: ble} do
      arm(ble)
      pad(ble, {:pressed, :up})
      assert_receive {:pulse, 0, 1650}

      send(ble, {:fake_stack, {:disconnected, 1, :connection_timeout}})
      assert_receive {:pulse, 0, 1500}
      flush_pulses()
      refute_receive {:pulse, 0, 1650}, 400
    end

    test "stops after max_hold_ms without a change, as if the app went away", %{ble: ble} do
      arm(ble)
      pad(ble, {:pressed, :up})
      assert_receive {:pulse, 0, 1650}

      assert text(1_500) == "stopped: held 1 s without a change\n"
      assert_receive {:pulse, 0, 1500}
    end

    test "2 disarms, stopping first", %{ble: ble} do
      arm(ble)
      pad(ble, {:pressed, :up})
      assert_receive {:pulse, 0, 1650}

      pad(ble, {:pressed, 2})
      assert_receive {:pulse, 0, 1500}
      assert text() =~ "disarm: ok"
      assert BB.Robot.Runtime.state(Robot) == :disarmed
    end
  end

  test "a port closing isn't the stack going down", %{ble: ble} do
    port = Port.open({:spawn_executable, System.find_executable("true")}, [])
    send(ble, {:EXIT, port, :normal})
    refute_receive {:attached, ^ble, _table, _services}, 1_500
  end

  test "asks for a short supervision timeout when the central chose a long one", %{ble: ble} do
    refute_receive {:connection_parameters, _, _}, 1_200

    send(ble, {:fake_stack, {:connected, 2, %{supervision_timeout: 500}}})
    assert_receive {:connection_parameters, 2, params}, 1_500
    assert params[:timeout] == 200
  end

  defp subscribe(ble, characteristic), do: Buggy.BLE.gatt_subscribe(ble, characteristic, true)
  defp write(ble, characteristic, data), do: Buggy.BLE.gatt_write(ble, characteristic, data)
  defp pad(ble, event), do: write(ble, :uart_rx, ControlPad.packet(event))

  defp arm(ble) do
    pad(ble, {:pressed, 1})
    assert text() == "arm: ok armed\n"
    flush_pulses()
  end

  defp pieces(binary, size) when byte_size(binary) <= size, do: [binary]

  defp pieces(binary, size) do
    <<piece::binary-size(^size), rest::binary>> = binary
    [piece | pieces(rest, size)]
  end

  # Collect UART notifications until they've stopped for a moment.
  defp text(timeout \\ 500) do
    receive do
      {:notified, :uart_tx, chunk} ->
        assert byte_size(chunk) <= 20
        chunk <> more_text()
    after
      timeout -> flunk("no text over the UART")
    end
  end

  defp more_text do
    receive do
      {:notified, :uart_tx, chunk} ->
        assert byte_size(chunk) <= 20
        chunk <> more_text()
    after
      100 -> ""
    end
  end

  defp flush_pulses do
    receive do
      {:pulse, _, _} -> flush_pulses()
    after
      0 -> :ok
    end
  end
end
