defmodule Buggy.Camera.SettingsTest do
  use ExUnit.Case, async: true

  alias Buggy.Camera.Settings

  test "defaults stream 640x480 at 30 fps, a keyframe a second" do
    {settings, []} = Settings.from_options([])
    args = Settings.rpicam_args(settings)

    assert pairs(args)["--width"] == "640"
    assert pairs(args)["--height"] == "480"
    assert pairs(args)["--intra"] == "30"
    assert pairs(args)["--bitrate"] == "1500000"
    refute "--mode" in args
    refute "--rotation" in args
  end

  test "turns the parameters into rpicam-vid arguments" do
    {settings, []} =
      Settings.from_options(
        resolution: "1280x960",
        sensor_mode: "1296x972",
        framerate: 25,
        bitrate_kbps: 4000,
        keyframe_interval: 0.5,
        exposure: "sport",
        ev: 0.5,
        sharpness: 1.5,
        denoise: "cdn_hq",
        rotate_180: true
      )

    args = pairs(Settings.rpicam_args(settings))

    assert args["--width"] == "1280"
    assert args["--height"] == "960"
    assert args["--mode"] == "1296:972"
    assert args["--framerate"] == "25"
    assert args["--bitrate"] == "4000000"
    assert args["--intra"] == "13"
    assert args["--exposure"] == "sport"
    assert args["--ev"] == "0.5"
    assert args["--sharpness"] == "1.5"
    assert args["--denoise"] == "cdn_hq"
    assert args["--rotation"] == "180"

    assert Settings.metadata(settings) == %{
             codec: :h264,
             width: 1280,
             height: 960,
             framerate: 25
           }
  end

  test "accepts sloppy but unambiguous sizes" do
    {settings, []} = Settings.from_options(resolution: " 960 X 720 ", sensor_mode: " auto ")
    assert {settings.width, settings.height, settings.sensor_mode} == {960, 720, :auto}
  end

  test "keeps the current value and warns when a string doesn't parse" do
    {current, []} = Settings.from_options(resolution: "1280x960", exposure: "sport")

    {settings, warnings} =
      Settings.from_options(
        [resolution: "1281x960", exposure: "blurry", sensor_mode: "big", framerate: 20],
        current
      )

    assert {settings.width, settings.height} == {1280, 960}
    assert settings.exposure == "sport"
    assert settings.sensor_mode == :auto
    assert settings.framerate == 20
    assert length(warnings) == 3
    assert Enum.any?(warnings, &String.starts_with?(&1, "video.resolution:"))
  end

  test "refuses sizes the Pi 3's encoder can't take" do
    {settings, [warning]} = Settings.from_options(resolution: "2592x1944")
    assert {settings.width, settings.height} == {640, 480}
    assert warning =~ "1920x1080"
  end

  test "ffmpeg stands in with the same size, rate, bitrate and keyframes" do
    {settings, []} =
      Settings.from_options(resolution: "320x240", framerate: 10, bitrate_kbps: 800)

    args = Settings.ffmpeg_args(settings)
    assert "testsrc2=size=320x240:rate=10" in args
    assert pairs(args)["-g"] == "10"
    assert pairs(args)["-b:v"] == "800k"
  end

  defp pairs(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Map.new(fn [k, v] -> {k, v} end)
  end
end
