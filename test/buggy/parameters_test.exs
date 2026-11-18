defmodule Buggy.ParametersTest do
  use ExUnit.Case, async: false

  alias Buggy.Parameters
  alias Buggy.Test.Robot

  setup do
    # As config :buggy, Buggy.Robot, params: [...] does for the real robot.
    Application.put_env(:buggy, Robot, params: [limits: [max_throttle: 0.25]])
    on_exit(fn -> Application.delete_env(:buggy, Robot) end)
    start_supervised!({Robot, Application.get_env(:buggy, Robot)})
    :ok
  end

  test "lists parameters by name, sorted, optionally under a prefix" do
    names = for {name, _path, _meta} <- Parameters.list(Robot), do: name
    assert names == Enum.sort(names)
    assert "limits.max_throttle" in names

    assert [{"video.resolution", [:video, :resolution], %{value: "640x480"}}, _rotate] =
             Parameters.list(Robot, "video")

    assert Parameters.list(Robot, "vid") == []
  end

  test "gets by name, without making atoms of unknown ones" do
    assert {:ok, [:limits, :max_throttle], %{value: 0.25, default: 0.3}} =
             Parameters.get(Robot, "limits.max_throttle")

    assert {:error, "no parameter limits.nope_" <> _} =
             Parameters.get(Robot, "limits.nope_#{System.unique_integer([:positive])}")
  end

  test "sets from text according to the type" do
    assert Parameters.set(Robot, "limits.max_throttle", "0.5") == {:ok, 0.5}
    assert Parameters.set(Robot, "calibration.esc_neutral_pulse", "1520") == {:ok, 1520}
    assert Parameters.set(Robot, "config.address", "0x41") == {:ok, 0x41}
    assert Parameters.set(Robot, "video.rotate_180", "on") == {:ok, true}
    assert Parameters.set(Robot, "video.resolution", ~s("1296x972")) == {:ok, "1296x972"}

    assert {:error, "not a number: fast"} = Parameters.set(Robot, "limits.max_throttle", "fast")
    assert {:error, message} = Parameters.set(Robot, "limits.max_throttle", "1.5")
    assert message =~ "1.5"
    assert BB.Parameter.get(Robot, [:limits, :max_throttle]) == {:ok, 0.5}
  end

  test "unset goes back to the configured value, or else the default" do
    {:ok, _} = Parameters.set(Robot, "limits.max_throttle", "0.5")
    assert Parameters.unset(Robot, "limits.max_throttle") == {:ok, 0.25}

    {:ok, _} = Parameters.set(Robot, "calibration.esc_neutral_pulse", "1520")
    assert Parameters.unset(Robot, "calibration.esc_neutral_pulse") == {:ok, 1500}
  end

  test "formats values and types for people" do
    assert Parameters.format(0.3) == "0.3"
    assert Parameters.format(nil) == "(none)"
    {:ok, _path, meta} = Parameters.get(Robot, "limits.max_throttle")
    assert Parameters.describe_type(meta) == "float 0.0..1.0"
  end
end
