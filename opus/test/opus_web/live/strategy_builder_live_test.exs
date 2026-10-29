defmodule OpusWeb.StrategyBuilderLiveTest do
  use OpusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Opus.Repo
  alias Opus.Trading.{LiveStrategy, LiveTrade, Recipe}

  @parameters %{
    "version" => "1",
    "strategy_name" => "Index RSI(2) dip-buy",
    "instrument" => "SPX500_USD",
    "granularity" => "D",
    "components" => %{
      "r" => %{
        "type" => "RsiReversion",
        "params" => %{"rsi_period" => 2, "oversold" => 20, "overbought" => 80}
      }
    },
    "entry" => %{"long" => "r.long"},
    "exit" => %{"long" => "r.exit_long"},
    "stop" => %{"type" => "AtrMultiple", "params" => %{"k" => 3.0, "period" => 14}},
    "sizing" => %{"type" => "RiskPct", "params" => %{"pct" => 0.01}}
  }

  setup do
    for schema <- [LiveTrade, LiveStrategy, Recipe], do: Repo.delete_all(schema)
    :ok
  end

  defp trading_recipe!(open_trade?) do
    now = DateTime.utc_now()

    strategy =
      Repo.insert!(%LiveStrategy{
        strategy_type: "composite",
        instrument: "SPX500_USD",
        granularity: "D",
        parameters: @parameters,
        enabled: true,
        created_at: now,
        updated_at: now
      })

    if open_trade? do
      Repo.insert!(%LiveTrade{
        live_strategy_id: strategy.id,
        instrument: "SPX500_USD",
        status: "open",
        entry_time: now,
        created_at: now,
        updated_at: now
      })
    end

    Repo.get!(LiveStrategy, strategy.id).strategy_id
  end

  # The test database has no recent candles, so there's nothing to preview
  # on (and config/test.exs points the engine client at a closed port).
  test "a new strategy starts empty and needs a working preview to save", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/strategies/new")

    assert html =~ "New strategy"
    assert html =~ "A block watches one thing about the price"
    assert html =~ "Start from an example"
    assert html =~ "Trend"
    assert html =~ "Is it going up or down?"

    html = view |> element("button", "+ RSI") |> render_click()
    assert html =~ "RSI(2) is below 20"
    assert html =~ "RSI(2) is back to 50 or higher"

    assert render_async(view) =~ "No instrument has recent bars at this timeframe."

    html = view |> form("#builder", form: %{name: ""}) |> render_submit(%{"then" => "draft"})
    assert html =~ "Give it a name first."

    view |> form("#builder", form: %{name: "Dip test"}) |> render_change()
    html = view |> form("#builder") |> render_submit(%{"then" => "draft"})
    assert html =~ "The engine checks the rules before saving"
  end

  test "a block explains itself and each setting, and an example fills the whole form", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/strategies/new")

    html = view |> element("button", "+ RSI") |> render_click()
    assert html =~ "How hard the price has been pushed one way lately"
    assert html =~ "Lower means fewer, more extreme dips count."

    {:ok, view, _html} = live(conn, ~p"/strategies/new")
    html = view |> element(~s(button[phx-value-id="dip_in_uptrend"])) |> render_click()

    assert html =~ ~s(value="Buy dips in an uptrend")
    assert html =~ ~s(name="form[rules][entry_long][refs][]" value="t.above")
    refute html =~ "Start from an example"
  end

  test "conditions are picked from a list and show as removable lines", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/strategies/new")
    view |> element("button", "+ RSI") |> render_click()

    html =
      view
      |> form("#builder")
      |> render_change(%{"add" => %{"entry_long" => "r.long"}})

    assert html =~ ~s(name="form[rules][entry_long][refs][]" value="r.long")
    assert html =~ "Add another condition…"

    html =
      view
      |> element(~s(button[phx-value-slot="entry_long"][phx-value-ref="r.long"]))
      |> render_click()

    refute html =~ ~s(name="form[rules][entry_long][refs][]" value="r.long")
  end

  test "the builder runs the rules over the whole history and offers the fragility check", %{
    conn: conn
  } do
    {:ok, spx} = Opus.Instruments.add("SPX500_USD", "index")
    today = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      "candles",
      for i <- 1..5 do
        %{
          instrument_id: spx.id,
          instrument: "SPX500_USD",
          granularity: "D",
          timestamp: DateTime.add(today, -i * 86_400, :second),
          open: 100.0,
          high: 101.0,
          low: 99.0,
          close: 100.0,
          volume: 1,
          complete: true
        }
      end
    )

    {:ok, view, _html} = live(conn, ~p"/strategies/new")
    html = view |> element("button", "+ RSI") |> render_click()

    assert html =~ "Over its whole history on SPX500_USD"
    # These bars are all inside the holdout: nothing to run it on.
    assert html =~ "No history from before the holdout to run it on."

    html = view |> element("button", ~r/Check \d+ nearby settings/) |> render_click()
    assert html =~ "Checking"
    assert render_async(view) =~ "Auro is not running."
  end

  test "a trading strategy opens locked, and unlocking can make a copy", %{conn: conn} do
    recipe_id = trading_recipe!(false)
    {:ok, view, html} = live(conn, ~p"/strategies/recipes/#{recipe_id}/edit")

    assert html =~ "Locked."
    assert html =~ "Switched on for SPX500_USD"
    assert html =~ ~s(<fieldset disabled)

    assert view |> element("button", "Unlock to edit") |> render_click() =~
             "How do you want to change it?"

    html = view |> element("button", "Edit a copy") |> render_click()
    assert html =~ "Copy of Index RSI(2) dip-buy"
    assert html =~ ~s[value="Index RSI(2) dip-buy (copy)"]
    refute html =~ "Locked."
  end

  test "a strategy that isn't trading can be deleted from the builder", %{conn: conn} do
    {:ok, recipe} =
      Opus.Trading.Recipes.create(%{
        name: "shop_test",
        granularity: "D",
        definition: Map.drop(@parameters, ~w(instrument granularity sizing))
      })

    {:ok, view, _html} = live(conn, ~p"/strategies/recipes/#{recipe.id}/edit")

    assert {:error, {:live_redirect, %{to: "/strategies"}}} =
             view |> element("button", "Delete") |> render_click()

    refute Repo.get(Recipe, recipe.id)
  end

  test "switching it off to edit waits for an open trade to close", %{conn: conn} do
    recipe_id = trading_recipe!(true)
    {:ok, view, _html} = live(conn, ~p"/strategies/recipes/#{recipe_id}/edit")

    view |> element("button", "Unlock to edit") |> render_click()
    html = view |> element("button", "Switch it off everywhere, then edit") |> render_click()

    assert html =~ "SPX500_USD has an open trade"
    assert html =~ "Locked."
  end
end
