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

  scope "/" do
    pipe_through([:browser])
    import BB.LiveView.Router
    bb_dashboard("/", robot: Buggy.Robot)
  end

  scope "/api", BuggyWeb do
    pipe_through(:api)
  end
end
