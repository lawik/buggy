defmodule Buggy.ParameterStoreTest do
  use ExUnit.Case, async: true

  alias Buggy.ParameterStore

  @moduletag :tmp_dir

  test "a saved value survives closing and reopening, in a directory it creates", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join([tmp_dir, "not", "there", "parameters.dets"])

    {:ok, store} = ParameterStore.init(__MODULE__, path: path)
    assert :ok = ParameterStore.save(store, [:calibration, :steering_left_pulse], 2100)
    assert :ok = ParameterStore.close(store)

    {:ok, store} = ParameterStore.init(__MODULE__, path: path)
    assert {:ok, [{[:calibration, :steering_left_pulse], 2100}]} = ParameterStore.load(store)
    ParameterStore.close(store)
  end

  test "an unreadable file is moved aside and a fresh one started", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "parameters.dets")
    # What the car had: an empty file, from a power cut as it was created.
    File.write!(path, "")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, store} = ParameterStore.init(__MODULE__, path: path)
        assert {:ok, []} = ParameterStore.load(store)
        assert :ok = ParameterStore.save(store, [:calibration, :steering_center_pulse], 1600)
        assert :ok = ParameterStore.close(store)
      end)

    assert log =~ "is unreadable"
    assert [aside] = Path.wildcard(path <> ".unreadable-*")
    assert File.read!(aside) == ""

    {:ok, store} = ParameterStore.init(__MODULE__, path: path)
    assert {:ok, [{[:calibration, :steering_center_pulse], 1600}]} = ParameterStore.load(store)
    ParameterStore.close(store)
  end

  test "a missing path is an error" do
    assert {:error, {:missing_option, :path}} = ParameterStore.init(__MODULE__, [])
  end

  test "forget/2 deletes one saved value, for good", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "parameters.dets")
    robot = Module.concat(__MODULE__, Forgetful)

    {:ok, store} = ParameterStore.init(robot, path: path)
    :ok = ParameterStore.save(store, [:limits, :max_throttle], 0.5)
    :ok = ParameterStore.save(store, [:calibration, :esc_neutral_pulse], 1520)

    assert :ok = ParameterStore.forget(robot, [:limits, :max_throttle])
    assert :ok = ParameterStore.forget(robot, [:never, :saved])
    :ok = ParameterStore.close(store)

    {:ok, store} = ParameterStore.init(robot, path: path)
    assert {:ok, [{[:calibration, :esc_neutral_pulse], 1520}]} = ParameterStore.load(store)
    ParameterStore.close(store)
  end

  test "forget/2 does nothing for a robot without a store" do
    assert :ok = ParameterStore.forget(Module.concat(__MODULE__, NoStore), [:a])
  end
end
