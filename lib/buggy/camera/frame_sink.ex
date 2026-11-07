defmodule Buggy.Camera.FrameSink do
  @moduledoc """
  Publishes decoded camera frames as rgb8 `BB.Message.Sensor.Image`.

  Takes rgb888 `%VideoInterop.Frame{}`s in binary storage, as
  `Membrane.V4L2.H264.Decoder` gives them with `output: :binary,
  pixel_format: :rgb888`, already scaled. At most `max_fps` a second are
  published; the rest are dropped, newest wins.
  """
  use Membrane.Sink

  alias BB.Message.Sensor.Image

  def_options robot: [spec: module()],
              topic: [spec: [atom()], description: "PubSub path to publish under"],
              frame_id: [spec: atom()],
              max_fps: [spec: pos_integer(), default: 10]

  def_input_pad :input, accepted_format: _any, flow_control: :push

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{opts: opts, interval: div(1000, opts.max_fps), last: nil}}
  end

  @impl true
  def handle_buffer(:input, %Membrane.Buffer{payload: %VideoInterop.Frame{} = frame}, _ctx, state) do
    now = System.monotonic_time(:millisecond)

    if state.last == nil or now - state.last >= state.interval do
      publish(frame, state.opts)
      {[], %{state | last: now}}
    else
      {[], state}
    end
  end

  defp publish(frame, opts) do
    %VideoInterop.Binary{data: data, planes: [%{offset: 0, stride: stride}]} = frame.storage

    {:ok, message} =
      Image.new(opts.frame_id,
        width: frame.visible_rect.width,
        height: frame.visible_rect.height,
        encoding: :rgb8,
        step: stride,
        data: data
      )

    BB.PubSub.publish(opts.robot, opts.topic, message)
  end
end
