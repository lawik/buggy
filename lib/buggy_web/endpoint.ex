defmodule BuggyWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :buggy

  @session_options [
    store: :cookie,
    key: "_buggy_key",
    signing_salt: "6XpbVAzd",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(Plug.Static, at: "/__bb_assets__", from: {:bb_liveview, "priv/static"}, gzip: false)

  plug(Plug.Static,
    at: "/",
    from: :buggy,
    gzip: not code_reloading?,
    only: BuggyWeb.static_paths(),
    raise_on_missing_only: code_reloading?
  )

  if code_reloading? do
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(BuggyWeb.Router)
end
