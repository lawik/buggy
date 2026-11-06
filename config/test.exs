import Config

config :phoenix, plug_init_mode: :runtime
config :logger, level: :warning

config :buggy,
       BuggyWeb.Endpoint,
       http: [ip: {127, 0, 0, 1}, port: 4002],
       secret_key_base: "RaYMNRnhj4CiafsAwM8vYXN6UV4zvb5F64Mx8K29dMCckfOWbYcom6WGnj2jKGYE",
       server: false
