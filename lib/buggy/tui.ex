defmodule Buggy.TUI do
  @moduledoc """
  bb_tui extension for the buggy: hold the arrow keys to drive.

  Up/down is throttle (capped by the `limits.max_throttle` parameter),
  left/right is full steering lock. Let go and the throttle returns to
  neutral and the steering straightens.

      elixir --name cli@<your-ip> --cookie buggy_cookie -S mix bb.tui \\
        --robot Buggy.Robot --node buggy@<buggy ip> --extension Buggy.TUI
  """
  use BB.TUI.Extension

  drive do
    publish({Buggy.Drive, :drive_tick})
    stop({Buggy.Drive, :drive_release})
  end

  panels do
    panel :buggy do
      title("Buggy")
      tab(:drive)
      readout("steering", joint(:steering), unit: :degree, decimals: 1)
      readout("max throttle", param([:limits, :max_throttle]), decimals: 2)
      readout("left lock µs", param([:calibration, :steering_left_pulse]))
      readout("right lock µs", param([:calibration, :steering_right_pulse]))
    end
  end
end
