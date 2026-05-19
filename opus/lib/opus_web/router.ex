defmodule OpusWeb.Router do
  use OpusWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api", OpusWeb do
    pipe_through(:api)

    get("/regimes", RegimeController, :index)
    get("/pipeline", PipelineController, :index)
    post("/pipeline/:config_id/promote", PipelineController, :promote)
  end

  scope "/", OpusWeb do
    pipe_through(:api)

    get("/regimes/heatmap", RegimeController, :heatmap)
    get("/account/equity-curve", AccountController, :equity_curve)
    get("/journal/kpis", JournalController, :kpis)
    get("/health/system", HealthController, :system)
    get("/positions/:trade_id/sparkline", PositionsController, :sparkline)
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:opus, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through([:fetch_session, :protect_from_forgery])

      live_dashboard("/dashboard", metrics: OpusWeb.Telemetry)
    end
  end
end
