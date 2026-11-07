defmodule Buggy.MixProject do
  use Mix.Project

  @app :buggy
  @version "0.1.0"
  @all_targets [
    :bbb,
    :mangopi_mq_pro,
    :qemu_aarch64,
    :rpi,
    :rpi0,
    :rpi0_2,
    :rpi2,
    :rpi3,
    :rpi4,
    :rpi5,
    :trellis,
    :x86_64
  ]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.20",
      archives: [nerves_bootstrap: "~> 1.17"],
      listeners: listeners(Mix.target(), Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}],
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Buggy.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:dns_cluster, "~> 0.1"},
      {:bandit, "~> 1.5"},
      {:phoenix, "~> 1.7"},
      {:phx_install, "~> 0.1", only: [:dev, :test], runtime: false},
      # Local fork: adds a 3D | Images tab to the visualisation panel for image
      # sensors, and stops the event stream dumping raw binaries into the page.
      {:bb_liveview, path: "../bb_liveview"},
      {:bb_mcp, "~> 0.3"},
      # Camera: rpicam-vid's hardware H.264 through Membrane, to the dashboard
      # over WebRTC.
      {:membrane_core, "~> 1.2"},
      {:membrane_h26x_plugin, "~> 0.11"},
      {:membrane_webrtc_plugin, "~> 0.26"},
      # Local fork: builds libsrtp from vendored source, as there's no
      # precompiled libsrtp for the Pi 3's 32-bit ARM and the Nerves system
      # doesn't ship one.
      {:ex_libsrtp, path: "../ex_libsrtp", override: true},
      # Local fork: bundlex archives static libs with a bare `ar`, and on a Mac
      # that's Apple's, which leaves an empty archive of the cross-compiled
      # objects. Every NIF that links one (ex_dtls through unifex, shmex)
      # then fails to load on the device, and WebRTC with it. The fork uses
      # Nerves's `$AR`.
      {:bundlex, path: "../bundlex", override: true},
      {:video_interop, "~> 0.1.2"},
      # Local: H.264 decoding on the Pi's bcm2835-codec, for the camera's raw
      # frames. Rustler builds its NIF into that repo's priv/native, shared by
      # every project that uses it, so run
      # `MIX_TARGET=rpi3 mix deps.compile membrane_v4l2_decoder --force`
      # before `mix firmware` if anything else built it since.
      {:membrane_v4l2_decoder, path: "../membrane_v4l2_decoder"},
      {:bb_tui, "~> 0.9"},
      {:nx_eigen, "~> 0.2"},
      # Local fork, on its `dev` branch (each change also has its own branch
      # for upstreaming): the controller takes its name from the `bb` path and
      # disarms through the robot registry, min/max pulse changes apply live
      # (the steering calibration), and a 0µs pulse turns the channel off
      # instead of erroring, which made every disarm fail.
      {:bb_servo_pca9685, path: "../bb_servo_pca9685"},
      {:bb, "~> 0.33"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      # Dependencies for all targets
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:logger_backends, "~> 1.0"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.5.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.12"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {:nerves_system_bbb, "~> 2.19", runtime: false, targets: :bbb},
      {:nerves_system_mangopi_mq_pro, "~> 0.6", runtime: false, targets: :mangopi_mq_pro},
      {:nerves_system_qemu_aarch64, "~> 0.1", runtime: false, targets: :qemu_aarch64},
      {:nerves_system_rpi, "~> 2.0", runtime: false, targets: :rpi},
      {:nerves_system_rpi0, "~> 2.0", runtime: false, targets: :rpi0},
      {:nerves_system_rpi0_2, "~> 2.0", runtime: false, targets: :rpi0_2},
      {:nerves_system_rpi2, "~> 2.0", runtime: false, targets: :rpi2},
      {:nerves_system_rpi3, "~> 2.0", runtime: false, targets: :rpi3},
      {:nerves_system_rpi4, "~> 2.0", runtime: false, targets: :rpi4},
      {:nerves_system_rpi5, "~> 2.0", runtime: false, targets: :rpi5},
      {:nerves_system_trellis, "~> 0.4", runtime: false, targets: :trellis},
      {:nerves_system_x86_64, "~> 1.24", runtime: false, targets: :x86_64}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is started at boot (see Buggy.Distribution), so anyone on
      # the network with this cookie gets a shell on the device. Set
      # BUGGY_COOKIE when building to use your own.
      cookie: System.get_env("BUGGY_COOKIE", "#{@app}_cookie"),
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  # Uncomment the following line if using Phoenix > 1.8.
  # defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []

  defp aliases() do
    [
      "assets.setup": ["esbuild.install --if-missing", "tailwind.install --if-missing"],
      "assets.build": ["compile", "esbuild buggy", "tailwind buggy"],
      "assets.deploy": ["esbuild buggy --minify", "tailwind buggy --minify", "phx.digest"],
      setup: ["deps.get", "assets.setup", "assets.build"]
    ]
  end
end
