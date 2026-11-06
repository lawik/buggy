import Config

config :nx, default_backend: NxEigen.Backend
Application.ensure_all_started(:logger_backends)
LoggerBackends.add(RingLogger)
