defmodule Buggy.Camera.Pipeline do
  @moduledoc """
  The camera's Membrane pipeline:

      source ── H.264 parser ── tee ──┬── WebRTC sink, one per viewer
                                       └── frames branch, while anyone wants Images

  Viewers come and go with `{:add_viewer, id, signaling}` and
  `{:remove_viewer, id}`, and the frames branch with `:start_frames` and
  `:stop_frames`. Each viewer is its own crash group, so a viewer whose
  connection breaks takes nothing else down; the owner hears
  `{Buggy.Camera.Pipeline, :viewer_down, id}`, and the same goes for the
  frames branch (`{Buggy.Camera.Pipeline, :frames_down}`). If the source program exits, the pipeline terminates
  with `{:shutdown, {:source_exited, status}}`.

  Everything hangs off the tee's push outputs, so nothing downstream can
  slow the camera.
  """
  use Membrane.Pipeline

  require Membrane.Logger

  alias Buggy.Camera.CommandSource

  @impl true
  def handle_init(_ctx, opts) do
    opts = Map.new(opts)

    spec =
      child(:source, %CommandSource{
        executable: opts.executable,
        args: opts.args,
        env: Map.get(opts, :env, [])
      })
      |> child(:parser, %Membrane.H264.Parser{
        output_alignment: :nalu,
        repeat_parameter_sets: true,
        generate_best_effort_timestamps: %{framerate: {opts.framerate, 1}}
      })
      |> child(:tee, Membrane.Tee)

    state = %{
      owner: opts.owner,
      frames: Map.get(opts, :frames),
      frames_running?: false
    }

    {[spec: spec], state}
  end

  @impl true
  def handle_info({:add_viewer, id, signaling}, _ctx, state) do
    spec =
      get_child(:tee)
      |> via_out(:push_output)
      |> via_in(:input, options: [kind: :video])
      |> child({:webrtc_sink, id}, %Membrane.WebRTC.Sink{
        signaling: signaling,
        tracks: [:video],
        video_codec: :h264,
        # LAN only: host candidates are all it needs, and a STUN server
        # would only slow ICE down.
        ice_servers: []
      })

    {[spec: {spec, group: {:viewer, id}, crash_group_mode: :temporary}], state}
  end

  def handle_info({:remove_viewer, id}, ctx, state) do
    if Map.has_key?(ctx.children, {:webrtc_sink, id}) do
      {[remove_children: {:viewer, id}], state}
    else
      {[], state}
    end
  end

  def handle_info(:start_frames, _ctx, %{frames: nil} = state), do: {[], state}
  def handle_info(:start_frames, _ctx, %{frames_running?: true} = state), do: {[], state}

  # The decoder converts and scales in native code, so frames arrive as
  # rgb888 at the size BB subscribers get.
  def handle_info(:start_frames, _ctx, state) do
    frames = state.frames

    spec =
      get_child(:tee)
      |> via_out(:push_output)
      |> child(:frames_parser, %Membrane.H264.Parser{output_alignment: :au})
      |> child(:decoder, %Membrane.V4L2.H264.Decoder{
        device: frames.device,
        output: :binary,
        pixel_format: :rgb888,
        size: {frames.width, frames.height},
        # nerves_system_rpi3 has 5 MB of CMA; the decoder's default
        # input buffers alone would take 16.
        output_buffer_size: 512 * 1024
      })
      |> child(:frame_sink, %Buggy.Camera.FrameSink{
        robot: frames.robot,
        topic: frames.topic,
        frame_id: frames.frame_id
      })

    {[spec: {spec, group: :frames, crash_group_mode: :temporary}],
     %{state | frames_running?: true}}
  end

  def handle_info(:stop_frames, _ctx, %{frames_running?: true} = state) do
    {[remove_children: :frames], %{state | frames_running?: false}}
  end

  def handle_info(:stop_frames, _ctx, state), do: {[], state}

  @impl true
  def handle_child_notification({:exited, status}, :source, _ctx, state) do
    {[terminate: {:shutdown, {:source_exited, status}}], state}
  end

  def handle_child_notification(_notification, _child, _ctx, state), do: {[], state}

  @impl true
  def handle_crash_group_down({:viewer, id}, _ctx, state) do
    send(state.owner, {__MODULE__, :viewer_down, id})
    {[], state}
  end

  def handle_crash_group_down(:frames, _ctx, state) do
    Membrane.Logger.warning("Camera frames branch crashed")
    send(state.owner, {__MODULE__, :frames_down})
    {[], %{state | frames_running?: false}}
  end
end
