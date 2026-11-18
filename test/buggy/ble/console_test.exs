defmodule Buggy.BLE.ConsoleTest do
  use ExUnit.Case, async: false

  alias Buggy.BLE.Console
  alias Buggy.Test.{FakeVintageNet, Robot}

  @wifi [vintage_net: FakeVintageNet]

  setup do
    Process.register(self(), :buggy_test_listener)
    start_supervised!(Robot)

    start_supervised!(
      {FakeVintageNet,
       ssid: "Home", psk: "home-password", reachable: %{"Home" => "home-password"}}
    )

    :ok
  end

  defp run(line), do: Console.run(line, Robot, @wifi)

  defp text(line) do
    assert [{:reply, text}] = run(line)
    text
  end

  test "help, and blank lines" do
    assert text("help") =~ "unset <name>"
    assert run("   ") == []
  end

  test "parameters: list, get, set, unset" do
    assert text("params limits") == "limits.max_throttle = 0.3\n"
    assert text("get limits.max_throttle") =~ "float 0.0..1.0, default 0.3\n  Cap on throttle"
    assert text("set limits.max_throttle 0.4") == "limits.max_throttle = 0.4\n"
    assert text("set video.resolution \"1296x972\"") == "video.resolution = 1296x972\n"
    assert text("unset limits.max_throttle") == "limits.max_throttle = 0.3 (default)\n"
    assert text("set limits.max_throttle lots") == "error: not a number: lots\n"
    assert text("get nothing.here") == "error: no parameter nothing.here\n"
    assert text("set limits.max_throttle") == "usage: set <name> <value>\n"
  end

  test "robot commands with their arguments in order or by name" do
    assert text("state") == "state: disarmed\n"
    assert text("steer -0.5") =~ "steer: error"
    assert text("arm") == "arm: ok armed\n"
    assert text("state") == "state: idle\n"

    assert text("steer -0.5") == "steer: ok angle_deg=12.5 steering=-0.5\n"
    assert_receive {:pulse, 1, 1650}

    assert text("throttle duration_ms=100 throttle=0.1") ==
             "throttle: ok duration_ms=100 throttle=0.1\n"

    assert text("steer left") == "steer: error steering: not a number: left\n"
    assert text("steer 1 2") == "steer: error too many arguments, try commands\n"
    assert text("steer speed=1") == "steer: error no argument speed\n"
    assert text("fly") == "unknown command fly, try help\n"
    assert text("commands") =~ "throttle throttle=0.2 duration_ms=1000\n"
  end

  test "a long command reports that it's running, then how it ended" do
    "arm: ok armed\n" = text("arm")
    assert [{:reply, "throttle: running\n"}, {:await, pid, "throttle"}] = run("throttle 0.1 800")
    assert Console.await(pid, "throttle") == "throttle: ok duration_ms=800 throttle=0.1\n"
  end

  test "wifi: status, and joining is handed back to Buggy.BLE" do
    assert text("wifi") == "wifi: Home, internet, 10.0.0.7\n"

    assert [{:reply, "wifi: joining My Net...\n"}, {:wifi_join, "My Net", "secret-pw"}] =
             run(~s(wifi "My Net" secret-pw))

    assert [_, {:wifi_join, "Cafe", ""}] = run("wifi Cafe")
  end
end
