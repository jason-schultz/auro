defmodule OpusWeb.Router do
  use OpusWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {OpusWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", OpusWeb do
    pipe_through(:browser)

    live("/accounts", AccountsLive)
    live("/journal", JournalLive)
    live("/options", OptionsLive)
    live("/instruments", InstrumentsLive)
  end

  scope "/api", OpusWeb do
    pipe_through(:api)

    get("/regimes", RegimeController, :index)
    get("/regimes/heatmap", RegimeController, :heatmap)
    get("/rules/state", RulesController, :state)
    get("/strategy-suspensions/open", CircuitBreakerController, :open)
    post("/strategy-suspensions/:id/reset", CircuitBreakerController, :reset)
    get("/pipeline", PipelineController, :index)
    post("/pipeline/:config_id/promote", PipelineController, :promote)
    post("/strategy-configs", PipelineController, :create_config)
    post("/strategy-configs/:config_id/run/:stage", PipelineController, :run_stage)
    get("/strategy-drafts", StrategyDraftController, :index)
    post("/strategy-drafts", StrategyDraftController, :create)
    put("/strategy-drafts/:id", StrategyDraftController, :update)
    delete("/strategy-drafts/:id", StrategyDraftController, :delete)
    get("/account/equity-curve", AccountController, :equity_curve)
    get("/portfolio/summary", AccountController, :portfolio_summary)
    get("/journal/kpis", JournalController, :kpis)
    get("/journal/execution-quality", JournalController, :execution_quality)
    get("/journal/strategy-performance", JournalController, :strategy_performance)
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
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: OpusWeb.Telemetry)
    end
  end
end
