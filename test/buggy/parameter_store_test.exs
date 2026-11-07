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

  test "a missing path is an error" do
    assert {:error, {:missing_option, :path}} = ParameterStore.init(__MODULE__, [])
  end
end
