defmodule Buggy.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    apply_log_levels()

    children =
      [
        # Children for all targets
        # Starts a worker by calling: Buggy.Worker.start_link(arg)
        # {Buggy.Worker, arg},
        BuggyWeb.Telemetry,
        {DNSCluster, [query: Application.get_env(:buggy, :dns_cluster_query) || :ignore]},
        {Phoenix.PubSub, [name: Buggy.PubSub]},
        BuggyWeb.Endpoint,
        # Served at /mcp by the router. `start: true` is needed because Anubis
        # otherwise only starts when `:phoenix, :serve_endpoints` is set, which
        # per-endpoint `server: true` (as on the device) doesn't do.
        {BB.MCP.Server, [transport: {:streamable_http, start: true}]}
      ] ++ robot_children() ++ [Buggy.Remote] ++ target_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Buggy.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Per-application overrides from `config :buggy, :log_levels`. An app that
  # isn't loaded is skipped.
  defp apply_log_levels do
    for {app, level} <- Application.get_env(:buggy, :log_levels, []) do
      Logger.put_application_level(app, level)
    end
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp target_children() do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
        #
        # Starts a worker by calling: Host.Worker.start_link(arg)
        # {Host.Worker, arg},
      ]
    end

    # The host has no PCA9685, so the robot only runs here when simulated
    # (`SIMULATE=1`). Otherwise the host is just a client, e.g. for
    # `mix bb.tui --node` against the device.
    defp robot_children do
      if System.get_env("SIMULATE"), do: [{Buggy.Robot, simulation: :kinematic}], else: []
    end
  else
    defp target_children() do
      [
        # Children for all targets except host
        # Starts a worker by calling: Target.Worker.start_link(arg)
        # {Target.Worker, arg},
        Buggy.Distribution
      ]
    end

    defp robot_children, do: [{Buggy.Robot, Application.get_env(:buggy, Buggy.Robot, [])}]
  end
end
