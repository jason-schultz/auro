defmodule OpusWeb.SafetyLiveTest do
  use OpusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Opus.Repo
  alias Opus.Trading.{AccountLimitChange, AccountLimits, LiveStrategy, LiveTrade, Suspension}

  @id "dddddddd-0000-0000-0000-000000000001"

  setup do
    for schema <- [AccountLimitChange, Suspension, LiveTrade, LiveStrategy],
        do: Repo.delete_all(schema)

    now = DateTime.utc_now()

    Repo.query!(
      "INSERT INTO instruments (symbol, oanda_symbol, exchange, currency, asset_class) VALUES ('SPX500_USD', 'SPX500_USD', 'OANDA', 'USD', 'index')"
    )

    Repo.insert!(%LiveStrategy{
      id: @id,
      strategy_type: "composite",
      instrument: "SPX500_USD",
      granularity: "D",
      parameters: %{"strategy_name" => "Dip-buy"},
      enabled: true,
      created_at: now,
      updated_at: now
    })

    for {pnl, hours} <- [{-0.01, 1}, {-0.02, 2}, {0.03, 3}] do
      Repo.insert!(%LiveTrade{
        live_strategy_id: @id,
        instrument: "SPX500_USD",
        status: "closed",
        pnl_percent: pnl,
        exit_time: DateTime.add(now, -hours, :hour),
        created_at: now,
        updated_at: now
      })
    end

    limits = AccountLimits.get()

    %{
      form: Map.new(AccountLimits.keys(), &{Atom.to_string(&1), to_string(limits[&1])}),
      limits: limits
    }
  end

  test "says where each rule stands", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/safety")

    assert html =~ "Account safety"
    assert html =~ "No trade is open"
    assert html =~ "Stock indices"
    # Two losses since the last win.
    assert html =~ "2 of 5 losses in a row"
  end

  test "tightening a rule saves at once and is logged", %{conn: conn, form: form} do
    {:ok, view, _html} = live(conn, ~p"/safety")

    html =
      view
      |> form("form[phx-submit=save]", Map.put(form, "risk_budget_pct", "4"))
      |> render_submit()

    assert html =~ "Saved."
    assert html =~ "Risk budget: 5"
    assert AccountLimits.get().risk_budget_pct == 4.0
  end

  test "loosening a rule asks first", %{conn: conn, form: form} do
    {:ok, view, _html} = live(conn, ~p"/safety")

    html =
      view
      |> form("form[phx-submit=save]", Map.put(form, "drawdown_pause_pct", "15"))
      |> render_submit()

    assert html =~ "This loosens a safety rule"
    assert AccountLimits.get().drawdown_pause_pct == 10

    html = view |> element("button", "Yes, loosen it") |> render_click()
    assert html =~ "Saved."
    assert AccountLimits.get().drawdown_pause_pct == 15.0
  end

  test "a value out of range says what's allowed", %{conn: conn, form: form} do
    {:ok, view, _html} = live(conn, ~p"/safety")

    html =
      view
      |> form("form[phx-submit=save]", Map.put(form, "max_open_per_group", "0"))
      |> render_submit()

    assert html =~ "Pick a number from 1 to 10."
  end

  test "exempting a strategy asks first", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/safety")

    html = view |> element("#breaker-#{@id} button") |> render_click()
    assert html =~ "won&#39;t switch it off"
    refute Repo.get!(LiveStrategy, @id).circuit_breaker_exempt

    view |> element("button", "Yes, loosen it") |> render_click()
    assert Repo.get!(LiveStrategy, @id).circuit_breaker_exempt
  end
end
