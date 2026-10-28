defmodule OpusWeb.StrategiesLiveTest do
  use OpusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Opus.Repo
  alias Opus.Trading.{LiveStrategy, LiveTrade, Recipe, Rule, Suspension}

  @trading_id "bbbbbbbb-0000-0000-0000-000000000001"
  @suspended_id "bbbbbbbb-0000-0000-0000-000000000002"
  @held_id "bbbbbbbb-0000-0000-0000-000000000003"

  setup do
    # Recipes too: the Rust DB tests leave theirs behind in the test database.
    for schema <- [Suspension, Rule, LiveTrade, LiveStrategy, Recipe], do: Repo.delete_all(schema)
    now = DateTime.utc_now()

    Repo.insert!(%LiveStrategy{
      id: @trading_id,
      strategy_type: "composite",
      instrument: "EU50_EUR",
      granularity: "D",
      parameters: %{"strategy_name" => "Euro dip-buy"},
      enabled: true,
      curator_mode: "pinned_on",
      created_at: now,
      updated_at: now
    })

    Repo.insert!(%Rule{
      live_strategy_id: @trading_id,
      enabled: true,
      reason: "composite: no regime gate",
      computed_at: now,
      regime_inputs: %{"composite" => "trending", "frames" => []}
    })

    Repo.insert!(%LiveStrategy{
      id: @held_id,
      strategy_type: "mean_reversion",
      instrument: "AUD_CAD",
      granularity: "H1",
      parameters: %{},
      enabled: true,
      curator_mode: "auto",
      created_at: now,
      updated_at: now
    })

    Repo.insert!(%Rule{
      live_strategy_id: @held_id,
      enabled: false,
      reason: "uncertain MR disabled (fail-closed)",
      computed_at: now,
      regime_inputs: %{}
    })

    Repo.insert!(%LiveStrategy{
      id: @suspended_id,
      strategy_type: "trend_following",
      instrument: "XAU_USD",
      granularity: "H1",
      parameters: %{},
      enabled: true,
      curator_mode: "auto",
      created_at: now,
      updated_at: now
    })

    Repo.insert!(%Suspension{
      live_strategy_id: @suspended_id,
      triggered_at: now,
      trigger_kind: "rolling_drawdown",
      trigger_detail: "-6.2% over 30d across 9 trades"
    })

    :ok
  end

  # config/test.exs points the Auro client at a closed port, so the page
  # renders from Opus's tables and reports the engine as unreachable.
  test "lists strategies with one status line each, without the engine", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/strategies")
    html = render(view)

    assert html =~ "Auro is not running."
    assert html =~ "3 of 3"
    assert html =~ "sending it"
    assert html =~ "Euro dip-buy"
    assert html =~ "Trading"
    assert html =~ "no trades yet"
    assert html =~ "Held"
    assert html =~ "uncertain MR disabled (fail-closed)"
    assert html =~ "Suspended"
    assert html =~ "-6.2% over 30d across 9 trades"
    assert html =~ ~s(href="/strategies/#{@trading_id}")
  end

  test "each recipe shows its rules, its lock and why tests are missing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/strategies")
    html = render(view)

    assert html =~ "2 recipes"
    assert html =~ "Locked"
    assert html =~ "Switched on for EU50_EUR"
    assert html =~ "not tested"
    refute html =~ "Never run through the testing pipeline."
    refute html =~ "No closed trades yet."
  end

  test "reset clears the suspension and the row loses its badge", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/strategies")

    html = view |> element("#strategy-#{@suspended_id} button", "Reset") |> render_click()

    refute html =~ "Suspended"
    assert html =~ "Suspension cleared"
  end

  test "flipping the switch needs the engine and says so when it is down", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/strategies")

    html = view |> element("#strategy-#{@trading_id} button", "Enabled") |> render_click()

    assert html =~ "Could not flip the switch: Auro is not running."
  end
end
