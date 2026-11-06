import Config

config :phoenix, stacktrace_depth: 20, plug_init_mode: :runtime
config :logger, default_formatter: [format: "[$level] $message
"]
config :buggy, dev_routes: true

config :buggy,
       BuggyWeb.Endpoint,
       check_origin: false,
       debug_errors: true,
       secret_key_base: "H6mKh7wvGgX/lP6jWIFSpkVS8IzlSe/yAVXER77qOp3pMR0IrjIkKKOOzlbJ+aIK"

# Code reloading and asset watchers need Mix and the source tree, so they only
# make sense on the host. The device's endpoint is configured in target.exs.
if Mix.target() == :host do
  config :buggy,
         BuggyWeb.Endpoint,
         http: [ip: {0, 0, 0, 0}, port: 4000],
         code_reloader: true,
         watchers: [
           esbuild: {Esbuild, :install_and_run, [:buggy, ["--sourcemap=inline", "--watch"]]},
           tailwind: {Tailwind, :install_and_run, [:buggy, ["--watch"]]}
         ],
         live_reload: [
           web_console_logger: true,
           patterns: [
             ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
             ~r"lib/.*_web/router\.ex$"E,
             ~r"lib/.*_web/(controllers|live|components)/.*\.(ex|heex)$"E
           ]
         ]
end
