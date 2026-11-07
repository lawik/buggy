defmodule Buggy.Camera.CommandSource do
  @moduledoc """
  An H.264 Annex B bytestream read from a program's stdout: `rpicam-vid` on
  the buggy, ffmpeg's test pattern on the host.

  The program stops with the element. Closing the port closes its stdout, so
  its next write fails. If it exits on its own, the element tells the
  pipeline with `{:exited, status}`.
  """
  use Membrane.Source

  alias Membrane.{Buffer, H264, RemoteStream}

  def_options executable: [spec: String.t(), description: "Absolute path to the program"],
              args: [spec: [String.t()], default: []],
              env: [spec: [{String.t(), String.t()}], default: []]

  def_output_pad :output,
    accepted_format: %RemoteStream{type: :bytestream, content_format: H264},
    flow_control: :push

  @impl true
  def handle_init(_ctx, opts), do: {[], %{opts: opts, port: nil}}

  @impl true
  def handle_playing(_ctx, state) do
    port =
      Port.open({:spawn_executable, state.opts.executable}, [
        :binary,
        :exit_status,
        args: state.opts.args,
        env: Enum.map(state.opts.env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
      ])

    format = %RemoteStream{type: :bytestream, content_format: H264}
    {[stream_format: {:output, format}], %{state | port: port}}
  end

  @impl true
  def handle_info({port, {:data, data}}, _ctx, %{port: port} = state) do
    {[buffer: {:output, %Buffer{payload: data}}], state}
  end

  def handle_info({port, {:exit_status, status}}, _ctx, %{port: port} = state) do
    {[notify_parent: {:exited, status}], %{state | port: nil}}
  end
end
