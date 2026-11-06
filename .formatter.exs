# Used by "mix format"
[
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "rootfs_overlay/etc/iex.exs"
  ],
  import_deps: [:phoenix, :bb_liveview, :bb_mcp, :bb_tui, :bb_servo_pca9685, :bb]
]
