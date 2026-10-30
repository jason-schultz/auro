defmodule Opus.Trading.BasketsTest do
  use Opus.DataCase, async: false

  alias Opus.Instruments
  alias Opus.Pipeline.{Coordinator, PromoteWorker, StrategyConfig, StrategyEvaluation}
  alias Opus.Trading.{Baskets, Recipe, Recipes, StrategyResults, Together}

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
          {"NAS100_USD", "index"},
          {"EUR_USD", "fx_major"}
        ] do
      bar!(symbol, class, ~U[2024-03-01 21:00:00Z])
    end

    {:ok, recipe} = Recipes.create(%{name: "Momo", granularity: "D", definition: @definition})
    %{recipe: recipe}
  end

  defp bar!(instrument, class, at) do
    {:ok, i} = Instruments.add(instrument, class)

    Repo.insert_all("candles", [
      %{
        instrument_id: i.id,
        instrument: instrument,
        granularity: "D",
        timestamp: at,
        open: 1.0,
        high: 1.0,
        low: 1.0,
        close: 1.0,
        complete: true
      }
    ])
  end

  test "the markets on offer have history before the holdout, and presets pick by class" do
    markets = Baskets.markets("D")
    assert Enum.map(markets, & &1.symbol) == ~w(EUR_USD NAS100_USD SPX500_USD XAU_USD)
    assert Baskets.preset(markets, "metals_energy_indices") == ~w(NAS100_USD SPX500_USD XAU_USD)
    assert Baskets.markets("H4") == []
  end

  test "together is one pipeline run holding every market, sorted, on the first", %{recipe: r} do
    assert {:ok, [%StrategyConfig{} = config]} =
             Baskets.submit(r, ~w(XAU_USD SPX500_USD), %{"mode" => "together"})

    assert config.instrument == "SPX500_USD"

    assert config.parameters["basket"] == %{
             "markets" => ~w(SPX500_USD XAU_USD),
             "mode" => "together"
           }

    assert [%{basket: %{"mode" => "together"}, stages: %{backtest: %{status: :pending}}}] =
             StrategyResults.for_baskets(r.definition, "D")

    # Not a run on SPX500 alone.
    assert StrategyResults.for_recipe(r.definition, "D") == []
  end

  test "ranked keeps its ranking settings next to the markets", %{recipe: r} do
    rank = %{"by" => "mo.roc", "every_bars" => "21", "long_top" => "1", "short_bottom" => "1"}

    assert {:ok, [config]} =
             Baskets.submit(r, ~w(SPX500_USD XAU_USD NAS100_USD), %{
               "mode" => "ranked",
               "rank" => rank
             })

    assert config.parameters["basket"]["rank"] == %{
             "by" => "mo.roc",
             "every_bars" => 21,
             "long_top" => 1,
             "short_bottom" => 1
           }

    assert Baskets.rank_choices(r.definition) == [{"mo.roc", "Momentum: Change from then (%)"}]
  end

  test "each separately is one ordinary run per market", %{recipe: r} do
    assert {:ok, [_, _]} = Baskets.submit(r, ~w(SPX500_USD XAU_USD), %{"mode" => "separate"})
    assert StrategyResults.for_baskets(r.definition, "D") == []
    assert length(StrategyResults.for_recipe(r.definition, "D")) == 2
  end

  test "what can't be tested is refused in plain words", %{recipe: r} do
    assert {:error, "Pick at least 2 markets."} =
             Baskets.submit(r, ~w(XAU_USD), %{"mode" => "together"})

    many = for i <- 1..41, do: "M#{i}"
    assert {:error, "Pick at most 40" <> _} = Baskets.submit(r, many, %{"mode" => "together"})

    rank = %{"by" => "mo.roc", "every_bars" => "21", "long_top" => "2", "short_bottom" => "1"}

    assert {:error, "It buys 2 and sells 1" <> _} =
             Baskets.submit(r, ~w(SPX500_USD XAU_USD), %{"mode" => "ranked", "rank" => rank})

    assert {:error, "Bars between rebalances" <> _} =
             Baskets.submit(r, ~w(SPX500_USD XAU_USD), %{
               "mode" => "ranked",
               "rank" => %{rank | "every_bars" => "0"}
             })

    {:ok, hourly} =
      Recipes.create(%{
        name: "Hourly",
        granularity: "H1",
        definition: Map.put(@definition, "strategy_name", "Hourly")
      })

    assert {:error, "Baskets are tested on daily or 4-hour bars only."} =
             Baskets.submit(hourly, ~w(SPX500_USD XAU_USD), %{"mode" => "together"})
  end

  test "a basket is never promoted to live, nor offered as a play", %{recipe: r} do
    {:ok, [config]} = Baskets.submit(r, ~w(SPX500_USD XAU_USD), %{"mode" => "together"})

    assert Coordinator.promote_to_live(config.id) == {:error, :basket}

    assert PromoteWorker.perform(%Oban.Job{args: %{"config_id" => config.id}}) ==
             {:cancel, :basket}

    Repo.insert!(%StrategyEvaluation{
      strategy_config_id: config.id,
      stage: "walk_forward",
      status: "passed",
      stats: %{"checks" => []},
      evaluated_at: DateTime.utc_now()
    })

    assert Together.choices().tested == []
  end

  test "the results page reads the basket's account from its backtest" do
    stats = %{
      "account_return" => 0.12,
      "account_max_drawdown" => 0.05,
      "num_trades" => 40,
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

    run = %{
      basket: %{"markets" => ~w(SPX500_USD XAU_USD)},
      stages: %{
        backtest: %{status: :passed, stats: stats},
        holdout: %{status: :pending, stats: nil}
      }
    }

    account = Baskets.account(run)
    refute account.holdout?
    assert [%{market: "XAU_USD"}, %{market: "SPX500_USD"}] = account.by_market
    assert [%{time: %DateTime{}}, _] = account.curve

    assert Baskets.account(%{
             run
             | stages: %{run.stages | backtest: %{status: :pending, stats: nil}}
           }) == nil
  end

  test "only a ranked basket is judged on months" do
    assert Baskets.by_months?(%{basket: %{"mode" => "ranked"}})
    refute Baskets.by_months?(%{basket: %{"mode" => "together"}})
  end
end
