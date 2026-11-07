defmodule Buggy.Camera.Settings do
  @moduledoc """
  The camera's settings, made from the robot's `video.*` parameters, and the
  `rpicam-vid` (or, on the host, ffmpeg) arguments they turn into.

  BB parameters have no enumerations, so the string ones are checked here. A
  value that doesn't parse leaves that setting as it was, with a warning.

  The OV5647 (Pi Camera v1) reads out in four sensor modes:

  | Mode      | Max fps | View        |                                     |
  |-----------|---------|-------------|-------------------------------------|
  | 640x480   | 62      | full        | binned and skipped: soft, aliased   |
  | 1296x972  | 46      | full        | 2x2 binned: the sharp one           |
  | 1920x1080 | 33      | centre crop | about ¾ of the width, ½ the height  |
  | 2592x1944 | 15      | full        | full resolution                     |

  `sensor_mode` picks one (`"auto"` lets libcamera choose, which for small
  sizes means the coarse 640x480 mode) and the ISP scales it to `resolution`.
  The Pi 3's H.264 encoder takes at most 1920x1080.
  """

  defstruct width: 640,
            height: 480,
            sensor_mode: :auto,
            framerate: 30,
            bitrate_kbps: 1500,
            keyframe_interval: 1.0,
            exposure: "normal",
            ev: 0.0,
            sharpness: 1.0,
            denoise: "auto",
            rotate_180: false,
            camera: 0

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          sensor_mode: :auto | {pos_integer(), pos_integer()},
          framerate: pos_integer(),
          bitrate_kbps: pos_integer(),
          keyframe_interval: number(),
          exposure: String.t(),
          ev: number(),
          sharpness: number(),
          denoise: String.t(),
          rotate_180: boolean(),
          camera: non_neg_integer()
        }

  @exposures ~w(normal sport short long)
  @denoise ~w(auto off cdn_off cdn_fast cdn_hq)
  @max_width 1920
  @max_height 1080

  @doc """
  Settings from the sensor's options. Anything missing or invalid keeps its
  value from `current`; the warnings say what was rejected.
  """
  @spec from_options(keyword(), t()) :: {t(), [String.t()]}
  def from_options(opts, current \\ %__MODULE__{}) do
    parsers = [
      resolution: &parse_resolution/1,
      sensor_mode: &parse_sensor_mode/1,
      framerate: &positive_integer/1,
      bitrate_kbps: &positive_integer/1,
      keyframe_interval: &positive_number/1,
      exposure: &one_of(&1, @exposures),
      ev: &number/1,
      sharpness: &non_negative_number/1,
      denoise: &one_of(&1, @denoise),
      rotate_180: &boolean/1,
      camera: &non_negative_integer/1
    ]

    Enum.reduce(parsers, {current, []}, fn {key, parse}, {settings, warnings} ->
      with {:ok, raw} <- Keyword.fetch(opts, key),
           {:ok, value} <- parse.(raw) do
        {put(settings, key, value), warnings}
      else
        :error ->
          {settings, warnings}

        {:error, expected} ->
          warning = "video.#{key}: #{inspect(Keyword.fetch!(opts, key))} isn't #{expected}"
          {settings, [warning | warnings]}
      end
    end)
    |> then(fn {settings, warnings} -> {settings, Enum.reverse(warnings)} end)
  end

  defp put(settings, :resolution, {width, height}), do: %{settings | width: width, height: height}
  defp put(settings, key, value), do: Map.put(settings, key, value)

  @doc "Arguments for `rpicam-vid`, writing baseline H.264 to stdout."
  @spec rpicam_args(t()) :: [String.t()]
  def rpicam_args(%__MODULE__{} = s) do
    # Baseline profile, as WebRTC expects, with SPS/PPS before every IDR so a
    # viewer can start at any keyframe.
    ~w(--nopreview --verbose 0 --flush --timeout 0 --codec h264 --profile baseline --inline --output -) ++
      [
        "--width",
        "#{s.width}",
        "--height",
        "#{s.height}",
        "--framerate",
        "#{s.framerate}",
        "--bitrate",
        "#{s.bitrate_kbps * 1000}",
        "--intra",
        "#{intra(s)}",
        "--exposure",
        s.exposure,
        "--ev",
        format(s.ev),
        "--sharpness",
        format(s.sharpness),
        "--denoise",
        s.denoise,
        "--camera",
        "#{s.camera}"
      ] ++ mode_args(s) ++ rotation_args(s)
  end

  @doc "Arguments for ffmpeg's test pattern, standing in for the camera on the host."
  @spec ffmpeg_args(t()) :: [String.t()]
  def ffmpeg_args(%__MODULE__{} = s) do
    ~w(-hide_banner -loglevel error -re -f lavfi -i) ++
      ["testsrc2=size=#{s.width}x#{s.height}:rate=#{s.framerate}"] ++
      ~w(-c:v libx264 -profile:v baseline -preset ultrafast -tune zerolatency -pix_fmt yuv420p -bf 0) ++
      ["-g", "#{intra(s)}", "-b:v", "#{s.bitrate_kbps}k", "-f", "h264", "-"]
  end

  @doc "What the dashboard shows about the stream."
  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{} = s) do
    %{codec: :h264, width: s.width, height: s.height, framerate: s.framerate}
  end

  # Frames between keyframes.
  defp intra(s), do: max(1, round(s.framerate * s.keyframe_interval))

  defp mode_args(%{sensor_mode: :auto}), do: []
  defp mode_args(%{sensor_mode: {w, h}}), do: ["--mode", "#{w}:#{h}"]

  defp rotation_args(%{rotate_180: true}), do: ["--rotation", "180"]
  defp rotation_args(_), do: []

  defp format(number) when is_integer(number), do: Integer.to_string(number)
  defp format(number), do: number |> Float.round(3) |> Float.to_string()

  defp parse_resolution(value) do
    with {:ok, {w, h}} <- parse_size(value),
         true <- rem(w, 2) == 0 and rem(h, 2) == 0,
         true <- w in 64..@max_width and h in 48..@max_height do
      {:ok, {w, h}}
    else
      _ -> {:error, "WIDTHxHEIGHT in even numbers, up to #{@max_width}x#{@max_height}"}
    end
  end

  defp parse_sensor_mode(value) when is_binary(value) do
    if String.trim(value) == "auto" do
      {:ok, :auto}
    else
      case parse_size(value) do
        {:ok, size} -> {:ok, size}
        :error -> {:error, ~s("auto" or a mode's WIDTHxHEIGHT)}
      end
    end
  end

  defp parse_sensor_mode(_value), do: {:error, ~s("auto" or a mode's WIDTHxHEIGHT)}

  defp parse_size(value) when is_binary(value) do
    case Regex.run(~r/^\s*(\d+)\s*[xX×]\s*(\d+)\s*$/u, value) do
      [_, w, h] -> {:ok, {String.to_integer(w), String.to_integer(h)}}
      nil -> :error
    end
  end

  defp parse_size(_value), do: :error

  defp one_of(value, allowed) when is_binary(value) do
    value = String.trim(value)
    if value in allowed, do: {:ok, value}, else: {:error, "one of #{Enum.join(allowed, ", ")}"}
  end

  defp one_of(_value, allowed), do: {:error, "one of #{Enum.join(allowed, ", ")}"}

  defp positive_integer(v) when is_integer(v) and v > 0, do: {:ok, v}
  defp positive_integer(_), do: {:error, "a positive integer"}

  defp non_negative_integer(v) when is_integer(v) and v >= 0, do: {:ok, v}
  defp non_negative_integer(_), do: {:error, "a non-negative integer"}

  defp positive_number(v) when is_number(v) and v > 0, do: {:ok, v}
  defp positive_number(_), do: {:error, "a positive number"}

  defp non_negative_number(v) when is_number(v) and v >= 0, do: {:ok, v}
  defp non_negative_number(_), do: {:error, "a number of at least 0"}

  defp number(v) when is_number(v), do: {:ok, v}
  defp number(_), do: {:error, "a number"}

  defp boolean(v) when is_boolean(v), do: {:ok, v}
  defp boolean(_), do: {:error, "true or false"}
end
