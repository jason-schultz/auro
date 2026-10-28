defmodule OpusWeb.StrategyLiveTest do
  use OpusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Opus.Repo
  alias Opus.Trading.{LiveStrategy, LiveTrade, Recipe, Rule, Suspension}

  @id "cccccccc-0000-0000-0000-000000000001"

  setup do
    # Recipes too: the Rust DB tests leave theirs behind in the test database.
    for schema <- [Suspension, Rule, LiveTrade, LiveStrategy, Recipe], do: Repo.delete_all(schema)
    Repo.delete_all("signal_events")
    now = DateTime.utc_now()

    Repo.insert!(%LiveStrategy{
      id: @id,
      strategy_type: "composite",
      instrument: "NAS100_USD",
      granularity: "M5",
      parameters: %{
        "strategy_name" => "NAS100 noise-area",
        "components" => %{
          "na" => %{
            "type" => "NoiseArea",
            "params" => %{"band_mult" => 1.0, "lookback_sessions" => 14}
          }
        },
        "entry" => %{"long" => "na.long", "short" => "na.short"},
        "exit" => %{"long" => %{"or" => ["na.exit_long", "na.session_close"]}},
        "stop" => %{"type" => "FromComponent", "params" => %{"component" => "na"}},
        "sizing" => %{"type" => "RiskPct", "params" => %{"pct" => 0.01}}
      },
      enabled: true,
      curator_mode: "pinned_on",
      created_at: now,
      updated_at: now
    })

    Repo.insert!(%Rule{
      live_strategy_id: @id,
      enabled: true,
      reason: "composite: no regime gate",
      computed_at: now,
      regime_inputs: %{
        "composite" => "uncertain",
        "frames" => [%{"frame" => "H1", "regime" => "trending", "adx" => 39.4}]
      }
    })

    Repo.insert!(%LiveTrade{
      live_strategy_id: @id,
      instrument: "NAS100_USD",
      direction: "Short",
      status: "open",
      entry_price: 29206.7,
      entry_time: DateTime.add(now, -5400, :second),
      created_at: now,
      updated_at: now
    })

    :ok
  end

  test "renders the strategy from Opus's tables while the engine is down", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/strategies/#{@id}")
    html = render(view)

    assert html =~ "NAS100 noise-area"
    assert html =~ "Auro is not running."
    assert html =~ "Trading"
    assert html =~ "composite: no regime gate"
    assert html =~ "H1 ADX 39.4 trending"
    assert html =~ "Short"
    assert html =~ "29,206.7"
    assert html =~ "How it trades"
    assert html =~ "the price breaks above the noise band"
    assert html =~ "or the US session ends (16:00 New York)"
    assert html =~ "Locked"
    assert html =~ "Unlock to edit"
    assert html =~ "Never run through the testing pipeline."
    assert html =~ "No completed candles stored"
    assert html =~ "unavailable while it is down"
  end

  test "an unknown id goes back to the list with a flash", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/strategies"}}} =
             live(conn, ~p"/strategies/dddddddd-0000-0000-0000-000000000009")
  end

  test "delete is refused while a trade is open, and the engine is needed for the switch", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/strategies/#{@id}")

    assert view |> element("button", "Delete") |> render() =~ "disabled"

    assert view |> element("button", "Enabled") |> render_click() =~
             "Could not flip the switch: Auro is not running."
  end
end
