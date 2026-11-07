defmodule Buggy.Remote.Frame do
  @moduledoc """
  Camera frames in the badge's wire format.

  A frame goes out as several messages, top to bottom:

      {:buggy_frame, seq, index, count, {width, rows}, pixels}

  `seq` is the same for every stripe of a frame, and stripe `index` covers
  rows `index * rows` up to `index * rows + rows - 1`. `pixels` holds exactly
  `width * rows * 4` bytes of RGBA8888 (R, G, B, A with A = 255; AtomGL treats
  A = 0 as transparent).

  Each stripe stays within 6,144 bytes. AtomVM's distribution controller
  reads 512 bytes at a time and re-appends the whole pending message on every
  read, so one big message would cost the badge megabytes of copying.
  """

  alias BB.Message.Sensor.Image

  @max_stripe_bytes 6144

  @doc """
  Scale `image` to `width` × `height` and send it to `to` as stripes.

  Returns `:error` without sending anything for encodings other than rgb8
  and mono8.
  """
  @spec send_frame(pid(), Image.t(), pos_integer(), pos_integer()) :: :ok | :error
  def send_frame(to, %Image{} = image, width, height) do
    with {:ok, rgba} <- rgba8(image, width, height) do
      {rows, stripes} = stripes(rgba, width, height)
      count = length(stripes)
      seq = :erlang.unique_integer([:positive, :monotonic])

      stripes
      |> Enum.with_index()
      |> Enum.each(fn {pixels, index} ->
        send(to, {:buggy_frame, seq, index, count, {width, rows}, pixels})
      end)
    end
  end

  @doc """
  An rgb8 or mono8 image as RGBA8888 at `width` × `height`, scaled by nearest
  neighbour.
  """
  @spec rgba8(Image.t(), pos_integer(), pos_integer()) :: {:ok, binary()} | :error
  def rgba8(%Image{encoding: encoding} = image, width, height)
      when encoding in [:rgb8, :mono8] do
    channels = if encoding == :rgb8, do: 3, else: 1

    if {width, height} == {image.width, image.height} and image.step == image.width * channels do
      {:ok, rgba_pixels(image.data, encoding)}
    else
      source_columns =
        for x <- 0..(width - 1), do: div(x * image.width, width) * channels

      rgba =
        for y <- 0..(height - 1), into: <<>> do
          row = binary_part(image.data, div(y * image.height, height) * image.step, image.step)

          for offset <- source_columns, into: <<>> do
            rgba_pixels(binary_part(row, offset, channels), encoding)
          end
        end

      {:ok, rgba}
    end
  end

  def rgba8(%Image{}, _width, _height), do: :error

  defp rgba_pixels(data, :rgb8), do: for(<<r, g, b <- data>>, into: <<>>, do: <<r, g, b, 255>>)
  defp rgba_pixels(data, :mono8), do: for(<<l <- data>>, into: <<>>, do: <<l, l, l, 255>>)

  @doc """
  Split an RGBA8888 image into stripes of whole rows, each within
  `max_bytes`. Every stripe has the same number of rows, the largest that
  divides `height` evenly and fits, so the last one isn't short.

  Returns `{rows_per_stripe, stripes}`.
  """
  @spec stripes(binary(), pos_integer(), pos_integer(), pos_integer()) ::
          {pos_integer(), [binary()]}
  def stripes(rgba, width, height, max_bytes \\ @max_stripe_bytes) do
    row_bytes = width * 4
    most = max(1, min(height, div(max_bytes, row_bytes)))
    rows = Enum.find(most..1//-1, &(rem(height, &1) == 0))
    stripe_bytes = rows * row_bytes

    {rows,
     for(
       index <- 0..(div(height, rows) - 1),
       do: binary_part(rgba, index * stripe_bytes, stripe_bytes)
     )}
  end
end
