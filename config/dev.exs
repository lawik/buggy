import Config

config :phoenix, stacktrace_depth: 20, plug_init_mode: :runtime
config :logger, default_formatter: [format: "[$level] $message
"]
config :buggy, dev_routes: true

config :buggy,
       BuggyWeb.Endpoint,
       http: [ip: {127, 0, 0, 1}, port: 4000],
       check_origin: false,
       code_reloader: true,
       debug_errors: true,
       secret_key_base: "H6mKh7wvGgX/lP6jWIFSpkVS8IzlSe/yAVXER77qOp3pMR0IrjIkKKOOzlbJ+aIK",
       watchers: [
         esbuild: {Esbuild, :install_and_run, [:buggy, ["--sourcemap=inline", "--watch"]]},
         tailwind: {Tailwind, :install_and_run, [:buggy, ["--watch"]]}
       ],
       live_reload: [
         web_console_logger: true,
         patterns: [
           ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
           ~r"lib/.*_web/router\.ex$",
           ~r"lib/.*_web/(controllers|live|components)/.*\.(ex|heex)$"
         ]
       ]
