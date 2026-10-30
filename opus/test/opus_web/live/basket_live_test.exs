defmodule OpusWeb.BasketLiveTest do
  use OpusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Opus.Instruments
  alias Opus.Pipeline.{StrategyConfig, StrategyEvaluation}
  alias Opus.Repo
  alias Opus.Trading.{Recipe, Recipes}

  @definition %{
    "version" => "1",
    "strategy_name" => "Momentum test",
    "components" => %{"mo" => %{"type" => "Momentum", "params" => %{"lookback" => 5}}},
    "entry" => %{"long" => "mo.up"},
    "exit" => %{"long" => "mo.down"},
    "stop" => %{"type" => "FixedPct", "params" => %{"pct" => -0.02}}
  }

  setup do
    Repo.delete_all(Recipe)

    for {symbol, class} <- [
          {"XAU_USD", "metal"},
          {"SPX500_USD", "index"},
          {"EUR_USD", "fx_major"}
        ] do
      {:ok, i} = Instruments.add(symbol, class)

      Repo.insert_all("candles", [
        %{
          instrument_id: i.id,
          instrument: symbol,
          granularity: "D",
          timestamp: ~U[2024-03-01 21:00:00Z],
          open: 1.0,
          high: 1.0,
          low: 1.0,
          close: 1.0,
          complete: true
        }
      ])
    end

    {:ok, recipe} = Recipes.create(%{name: "Momo", granularity: "D", definition: @definition})
    %{recipe: recipe}
  end

  test "a preset picks its markets and a together run starts", %{conn: conn, recipe: recipe} do
    {:ok, view, html} = live(conn, ~p"/strategies/recipes/#{recipe.id}/basket")
    assert html =~ "Test it on several markets"
    assert html =~ "No basket test of this strategy yet."

    html = view |> element("button", "Metals, energy and indices") |> render_click()
    assert html =~ "2 picked, up to 40"

    html = view |> form("#basket-form") |> render_submit()
    assert html =~ "The basket test is running."
    assert html =~ "Testing 2 markets as one account."
    assert [%StrategyConfig{instrument: "SPX500_USD"}] = Repo.all(StrategyConfig)
  end

  test "a finished run says what happened, what to do, and each market's share",
       %{conn: conn, recipe: recipe} do
    {:ok, [config]} =
      Opus.Trading.Baskets.submit(recipe, ~w(SPX500_USD XAU_USD), %{"mode" => "together"})

    stats = %{
      "account_return" => 0.12,
      "account_max_drawdown" => 0.05,
      "num_trades" => 40,
      "checks" => [
        %{
          "metric" => "t_stat",
          "operator" => "gte",
          "required" => 2.0,
          "actual" => 1.1,
          "passed" => false
        }
      ],
      "basket" => %{
        "from" => "2015-01-01T21:00:00Z",
        "to" => "2025-10-01T21:00:00Z",
        "annual_return" => 0.011,
        "by_market" => [
          %{"market" => "SPX500_USD", "trades" => 25, "wins" => 12, "account_return" => -0.02},
          %{"market" => "XAU_USD", "trades" => 15, "wins" => 9, "account_return" => 0.14}
        ],
        "curve" => [
          %{"time" => "2015-01-01T21:00:00Z", "equity" => 0.0, "drawdown" => 0.0},
          %{"time" => "2025-10-01T21:00:00Z", "equity" => 0.12, "drawdown" => 0.0}
        ]
      }
    }

    Repo.insert!(%StrategyEvaluation{
      strategy_config_id: config.id,
      stage: "backtest",
      status: "failed",
      stats: stats,
      failure_reason: "t_stat: 1.1000 is below minimum 2.0000",
      evaluated_at: DateTime.utc_now()
    })

    {:ok, _view, html} = live(conn, ~p"/strategies/recipes/#{recipe.id}/basket")
    assert html =~ "On 2 markets as one account, it made +12.0%"
    assert html =~ "It failed the backtest"
    assert html =~ "XAU_USD added the most (+14.0%)"
    assert html =~ "The account over time"
  end

  test "a ranked run is told in months of results, its drop valued every day",
       %{conn: conn, recipe: recipe} do
    rank = %{"by" => "mo.roc", "every_bars" => "21", "long_top" => "1", "short_bottom" => "1"}

    {:ok, [config]} =
      Opus.Trading.Baskets.submit(recipe, ~w(EUR_USD SPX500_USD XAU_USD), %{
        "mode" => "ranked",
        "rank" => rank
      })

    stats = %{
      "account_return" => 0.30,
      "account_max_drawdown" => 0.14,
      "num_trades" => 26,
      "num_months" => 30,
      "judged_on" => "months",
      "drawdown_valued" => "every_close",
      "checks" => [
        %{
          "metric" => "num_months",
          "operator" => "gte",
          "required" => 36.0,
          "actual" => 30.0,
          "passed" => false
        }
      ],
      "basket" => %{
        "from" => "2016-01-01T21:00:00Z",
        "to" => "2018-07-01T21:00:00Z",
        "annual_return" => 0.11,
        "by_market" => [],
        "curve" => []
      }
    }

    Repo.insert!(%StrategyEvaluation{
      strategy_config_id: config.id,
      stage: "backtest",
      status: "failed",
      stats: stats,
      failure_reason: "num_months: 30.0000 is below minimum 36.0000",
      evaluated_at: DateTime.utc_now()
    })

    {:ok, _view, html} = live(conn, ~p"/strategies/recipes/#{recipe.id}/basket")
    assert html =~ "over 30 months of results (26 positions held across re-ranks)"
    assert html =~ "(valued every day, open positions included)"
    assert html =~ "Months of results 30 (needs at least 36)"
    assert html =~ "judged the way the"
  end

  test "a recipe on hourly bars says baskets need daily or 4-hour bars", %{conn: conn} do
    {:ok, hourly} =
      Recipes.create(%{
        name: "Hourly",
        granularity: "H1",
        definition: Map.put(@definition, "strategy_name", "Hourly")
      })

    {:ok, _view, html} = live(conn, ~p"/strategies/recipes/#{hourly.id}/basket")
    assert html =~ "daily or 4-hour bars only"
    refute html =~ "basket-form"
  end
end
