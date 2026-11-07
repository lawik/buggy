defmodule BuggyWeb.Router do
  use BuggyWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BuggyWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  # MCP over Streamable HTTP. BB.MCP.Server's transport doesn't open a
  # listener of its own, so it has to be mounted here.
  scope "/" do
    import BB.MCP.Router
    bb_mcp("/mcp")
  end

  scope "/" do
    pipe_through([:browser])
    import BB.LiveView.Router
    # Hold-to-drive in the dashboard, with the same functions bb_tui's drive
    # extension (Buggy.TUI) uses.
    bb_dashboard("/",
      robot: Buggy.Robot,
      drive: [publish: {Buggy.Drive, :drive_tick}, stop: {Buggy.Drive, :drive_release}]
    )
  end

  scope "/api", BuggyWeb do
    pipe_through(:api)
  end
end
