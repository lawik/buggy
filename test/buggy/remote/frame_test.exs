defmodule Buggy.Remote.FrameTest do
  use ExUnit.Case, async: true

  alias BB.Message.Sensor.Image
  alias Buggy.Remote.Frame

  defp image(width, height, encoding, data) do
    channels = if encoding == :rgb8, do: 3, else: 1

    %Image{
      width: width,
      height: height,
      encoding: encoding,
      is_bigendian: false,
      step: width * channels,
      data: data
    }
  end

  describe "rgba8/3" do
    test "adds opaque alpha to rgb8 at the same size" do
      img = image(2, 1, :rgb8, <<1, 2, 3, 4, 5, 6>>)
      assert Frame.rgba8(img, 2, 1) == {:ok, <<1, 2, 3, 255, 4, 5, 6, 255>>}
    end

    test "spreads mono8 over the colour channels" do
      img = image(2, 1, :mono8, <<7, 9>>)
      assert Frame.rgba8(img, 2, 1) == {:ok, <<7, 7, 7, 255, 9, 9, 9, 255>>}
    end

    test "scales by nearest neighbour" do
      # 2x2 with a distinct value per pixel, scaled to 4x4 and to 1x1.
      img = image(2, 2, :mono8, <<10, 20, 30, 40>>)

      {:ok, up} = Frame.rgba8(img, 4, 4)
      grey = for <<l, l, l, 255 <- up>>, do: l
      assert grey == [10, 10, 20, 20, 10, 10, 20, 20, 30, 30, 40, 40, 30, 30, 40, 40]

      assert Frame.rgba8(img, 1, 1) == {:ok, <<10, 10, 10, 255>>}
    end

    test "refuses encodings it can't handle" do
      assert Frame.rgba8(image(1, 1, :bgr8, <<1, 2, 3>>), 1, 1) == :error
    end
  end

  describe "stripes/4" do
    test "uses the most rows that fit and divide the height, like the badge expects" do
      rgba = :binary.copy(<<0, 0, 0, 255>>, 160 * 120)
      {rows, stripes} = Frame.stripes(rgba, 160, 120, 6144)

      assert rows == 8
      assert length(stripes) == 15
      assert Enum.all?(stripes, &(byte_size(&1) == 160 * 8 * 4))
      assert IO.iodata_to_binary(stripes) == rgba
    end

    test "falls back to one row per stripe when a row alone is too big" do
      {rows, stripes} = Frame.stripes(:binary.copy(<<1>>, 4 * 4 * 3), 4, 3, 8)
      assert rows == 1
      assert length(stripes) == 3
    end
  end

  test "send_frame/4 sends every stripe of one frame, top to bottom" do
    img = image(160, 120, :rgb8, :binary.copy(<<1, 2, 3>>, 160 * 120))
    assert Frame.send_frame(self(), img, 160, 120) == :ok

    for index <- 0..14 do
      assert_receive {:buggy_frame, seq, ^index, 15, {160, 8}, pixels}
      assert is_integer(seq)
      assert byte_size(pixels) == 5120
      assert binary_part(pixels, 0, 4) == <<1, 2, 3, 255>>
    end

    refute_receive {:buggy_frame, _, _, _, _, _}
  end
end
