defmodule Opus.Trading.StrategiesTest do
  use Opus.DataCase, async: false

  import Ecto.Query

  alias Opus.Instruments
  alias Opus.Pipeline.{StrategyConfig, StrategyEvaluation}
  alias Opus.Repo
  alias Opus.Trading.{LiveStrategy, LiveTrade, Recipe, Rule, Strategies, Suspension}

  @enabled_id "aaaaaaaa-0000-0000-0000-000000000001"
  @held_id "aaaaaaaa-0000-0000-0000-000000000002"

  setup do
    # Recipes too: the Rust DB tests leave theirs behind in the test database.
    for schema <- [Suspension, Rule, LiveTrade, LiveStrategy, Recipe], do: Repo.delete_all(schema)
    Repo.delete_all("signal_events")
    now = DateTime.utc_now()

    Repo.insert!(%LiveStrategy{
      id: @enabled_id,
      strategy_type: "composite",
      instrument: "NAS100_USD",
      granularity: "D",
      parameters: %{"strategy_name" => "Index RSI(2) dip-buy"},
      enabled: true,
      curator_mode: "pinned_on",
      created_at: now,
      updated_at: now
    })

    Repo.insert!(%LiveStrategy{
      id: @held_id,
      strategy_type: "mean_reversion",
      instrument: "AUD_CAD",
      granularity: "H1",
      parameters: %{},
      enabled: false,
      curator_mode: "pinned_off",
      created_at: now,
      updated_at: now
    })

    Repo.insert!(%Rule{
      live_strategy_id: @enabled_id,
      enabled: false,
      reason: "uncertain MR disabled (fail-closed) — H4:24.6 H1:39.4",
      computed_at: now,
      regime_inputs: %{
        "composite" => "uncertain",
        "frames" => [
          %{"frame" => "H4", "regime" => "uncertain", "adx" => 24.63},
          %{"frame" => "H1", "regime" => "trending", "adx" => 39.44}
        ]
      }
    })

    Repo.insert!(%Suspension{
      live_strategy_id: @held_id,
      triggered_at: now,
      trigger_kind: "consecutive_losses",
      trigger_detail: "3 losing trades in a row"
    })

    Repo.insert!(%LiveTrade{
      live_strategy_id: @enabled_id,
      instrument: "NAS100_USD",
      status: "open",
      entry_time: now,
      created_at: now,
      updated_at: now
    })

    Repo.insert_all("signal_events", [
      signal(@enabled_id, "opened_long", DateTime.add(now, -3600, :second)),
      signal(@enabled_id, "entry_rejected", now)
    ])

    :ok
  end

  defp signal(strategy_id, action, at) do
    %{
      strategy_id: Ecto.UUID.dump!(strategy_id),
      strategy_type: "composite",
      instrument: "NAS100_USD",
      granularity: "D",
      action: action,
      price: 20_000.0,
      reason: "#{action} reason",
      timestamp: at,
      payload: %{}
    }
  end

  test "list/0 puts enabled strategies first and joins what Opus knows about each" do
    assert [enabled, held] = Strategies.list()

    assert enabled.id == @enabled_id
    assert enabled.name == "Index RSI(2) dip-buy"
    assert enabled.rule.enabled == false
    assert enabled.rule.composite == "uncertain"
    assert [%{frame: "H4", adx: 24.63}, %{frame: "H1", regime: "trending"}] = enabled.rule.frames
    assert enabled.open_trades == 1
    assert enabled.last_signal.action == "entry_rejected"
    assert enabled.suspension == nil

    assert held.name == "Mean reversion"
    assert held.rule == nil
    assert held.suspension.trigger_detail == "3 losing trades in a row"
    assert held.open_trades == 0
    assert held.last_signal == nil
  end

  test "reset_suspension/1 clears open suspensions once, then reports none open" do
    assert {:ok, 1} = Strategies.reset_suspension(@held_id)
    assert {:error, :none_open} = Strategies.reset_suspension(@held_id)
    assert {:error, :invalid_id} = Strategies.reset_suspension("not-a-uuid")

    assert Repo.one(from(s in Suspension, select: s.cleared_by)) == "manual"
    assert [%{suspension: nil}] = Enum.filter(Strategies.list(), &(&1.id == @held_id))
  end

  test "regime_summary/1 reads string or atom keys and tolerates missing inputs" do
    assert Strategies.regime_summary(nil) == {nil, []}
    assert Strategies.regime_summary(%{}) == {nil, []}

    assert {"trending", [%{frame: "H4", regime: "trending", adx: 51.0}]} =
             Strategies.regime_summary(%{
               composite: :trending,
               frames: [%{frame: "H4", regime: :trending, adx: 51.0}]
             })
  end

  test "stats/0 reports the engine as unreachable instead of raising" do
    assert {:error, %{reason: :econnrefused}} = Strategies.stats()
  end

  test "get/1 assembles the detail page from Opus's tables and marks the engine down" do
    {:ok, nas} = Opus.Instruments.add("NAS100_USD", "index")
    t0 = ~U[2026-10-22 14:00:00Z]

    Repo.insert_all(
      "candles",
      for i <- 0..4 do
        %{
          instrument_id: nas.id,
          instrument: "NAS100_USD",
          granularity: "D",
          timestamp: DateTime.add(t0, i * 86_400, :second),
          open: 100.0 + i,
          high: 102.0 + i,
          low: 99.0 + i,
          close: 101.0 + i,
          volume: 1,
          complete: i < 4
        }
      end
    )

    assert {:ok, detail} = Strategies.get(@enabled_id)

    assert detail.name == "Index RSI(2) dip-buy"
    assert detail.open_trade.status == "open"
    assert length(detail.trades) == 1
    assert [%{action: "entry_rejected"}, %{action: "opened_long"}] = detail.signals
    # Only the four completed bars, oldest first.
    assert Enum.map(detail.candles, & &1.close) == [101.0, 102.0, 103.0, 104.0]
    assert detail.stats == nil and detail.indicators == nil
    assert %{reason: :econnrefused} = detail.engine_error
    assert detail.logic == %{components: [], rules: [], settings: []}

    assert Strategies.get("not-a-uuid") == :error
    assert Strategies.get("dddddddd-0000-0000-0000-000000000009") == :error
  end

  test "logic/1 explains composite parameters and lists legacy ones plainly" do
    composite = %{
      "components" => %{
        "r" => %{"type" => "RsiReversion", "params" => %{"rsi_period" => 2, "oversold" => 20}},
        "t" => %{"type" => "MaFilter", "params" => %{"period" => 100, "ma_type" => "sma"}}
      },
      "entry" => %{"long" => %{"and" => ["r.long", "t.above"]}},
      "exit" => %{"long" => "r.exit_long"},
      "stop" => %{"type" => "AtrMultiple", "params" => %{"k" => 3.0, "period" => 14}},
      "sizing" => %{"type" => "RiskPct", "params" => %{"pct" => 0.005}},
      "max_hold_bars" => 10
    }

    logic = Strategies.logic(composite)

    assert [
             %{key: "r", type: "RsiReversion", params: [{"oversold", "20"}, {"rsi_period", "2"}]},
             %{key: "t"}
           ] =
             logic.components

    assert logic.rules == [
             {"Long when", "r.long and t.above"},
             {"Exit long", "r.exit_long"},
             {"Stop", "AtrMultiple (k 3.0, period 14)"},
             {"Sizing", "RiskPct (pct 0.005)"},
             {"Max hold", "10 bars"}
           ]

    assert Strategies.logic(%{
             "ma_period" => 20,
             "entry_threshold" => 0.02,
             "strategy_name" => "x"
           }).settings ==
             [{"entry_threshold", "0.02"}, {"ma_period", "20"}]
  end

  describe "recipes/0" do
    @spx_id "aaaaaaaa-0000-0000-0000-000000000003"

    setup do
      now = DateTime.utc_now()

      # Same rules as the NAS100 row, on another instrument: same recipe.
      Repo.insert!(%LiveStrategy{
        id: @spx_id,
        strategy_type: "composite",
        instrument: "SPX500_USD",
        granularity: "D",
        parameters: %{"strategy_name" => "Index RSI(2) dip-buy"},
        enabled: false,
        curator_mode: "pinned_off",
        created_at: now,
        updated_at: now
      })

      with :error <- Instruments.id_for("NAS100_USD"), do: Instruments.add("NAS100_USD", "index")

      config =
        %StrategyConfig{}
        |> StrategyConfig.changeset(%{
          instrument: "NAS100_USD",
          granularity: "D",
          strategy_type: "composite",
          parameters: %{"strategy_name" => "Index RSI(2) dip-buy"}
        })
        |> Repo.insert!()

      for {stage, status, stats, reason} <- [
            {"backtest", "passed", %{"total_return" => 0.43, "num_trades" => 118, "checks" => []},
             nil},
            {"walk_forward", "failed", nil, "out-of-sample Sharpe below 0.05"}
          ] do
        Repo.insert!(%StrategyEvaluation{
          strategy_config_id: config.id,
          stage: stage,
          status: status,
          stats: stats,
          failure_reason: reason,
          evaluated_at: now
        })
      end

      Repo.insert!(%LiveTrade{
        live_strategy_id: @enabled_id,
        instrument: "NAS100_USD",
        status: "closed",
        pnl: 84.44,
        entry_time: DateTime.add(now, -86_400, :second),
        exit_time: now,
        created_at: now,
        updated_at: now
      })

      :ok
    end

    test "groups instruments under one recipe and locks it while one is trading" do
      [dip_buy, held] = Strategies.recipes()

      assert dip_buy.name == "Index RSI(2) dip-buy"
      assert dip_buy.timeframe == "daily bars"
      assert Enum.map(dip_buy.assignments, & &1.instrument) == ["NAS100_USD", "SPX500_USD"]
      assert [%{instrument: "NAS100_USD"}] = dip_buy.locked_by

      assert held.locked_by == []
    end

    test "a pass from before the Oct 28 rules reads as that, not as passed" do
      from(e in StrategyEvaluation, where: e.stage == "backtest")
      |> Repo.update_all(set: [stats: %{"total_return" => 0.43, "num_trades" => 118}])

      [dip_buy, _held] = Strategies.recipes()
      [nas, _spx] = dip_buy.assignments

      assert %{status: :old_pass, reason: reason} = nas.results.backtest
      assert reason =~ "before Oct 28"
    end

    test "an archived run is marked, and a trading instrument keeps its own results" do
      [config] = Repo.all(StrategyConfig)
      with :error <- Instruments.id_for("DE30_EUR"), do: Instruments.add("DE30_EUR", "index")

      %StrategyConfig{}
      |> StrategyConfig.changeset(%{
        instrument: "DE30_EUR",
        granularity: "D",
        strategy_type: "composite",
        parameters: Map.put(config.parameters, "instrument", "DE30_EUR")
      })
      |> Repo.insert!()

      Repo.update_all(StrategyConfig, set: [archived_at: DateTime.utc_now()])

      [dip_buy, _held] = Strategies.recipes()
      [nas, _spx] = dip_buy.assignments

      assert [%{instrument: "DE30_EUR", archived: true}] = dip_buy.runs
      # NAS100 trades on the recipe; its own run shows though archived.
      assert %{status: :passed, stats: %{"num_trades" => 118}} = nas.results.backtest
    end

    test "the nearby-settings test sits between Monte Carlo and the holdout, except for older runs" do
      from(e in StrategyEvaluation, where: e.stage == "walk_forward")
      |> Repo.update_all(set: [status: "passed", stats: %{"checks" => []}, failure_reason: nil])

      [config_id] = Repo.all(from(c in StrategyConfig, select: c.id))

      for stage <- ~w(monte_carlo holdout) do
        Repo.insert!(%StrategyEvaluation{
          strategy_config_id: config_id,
          stage: stage,
          status: "passed",
          stats: %{"checks" => []}
        })
      end

      ran_on = fn at -> Repo.update_all(StrategyConfig, set: [inserted_at: at]) end
      nas = fn -> hd(hd(Strategies.recipes()).assignments) end

      # Before it joined: it was never run, and the holdout followed Monte Carlo.
      ran_on.(~U[2026-10-20 12:00:00.000000Z])
      assert %{status: :not_run, reason: reason} = nas.().results.parameter_stability
      assert reason =~ "joined the pipeline on Oct 30"
      assert nas.().results.holdout.status == :passed

      # After: a Monte Carlo pass means it's next, and the holdout waits on it.
      ran_on.(~U[2026-11-02 12:00:00.000000Z])
      from(e in StrategyEvaluation, where: e.stage == "holdout") |> Repo.delete_all()
      assert nas.().results.parameter_stability.status == :pending
      assert %{status: :not_run} = nas.().results.holdout

      Repo.insert!(%StrategyEvaluation{
        strategy_config_id: config_id,
        stage: "parameter_stability",
        status: "failed",
        stats: %{"checks" => []},
        failure_reason: "Moving period (t, MaFilter) from 200 to 201 dropped the Sharpe"
      })

      assert nas.().results.holdout.reason ==
               "Skipped because the nearby-settings test failed."
    end

    test "says what each test found, and why a test has no result" do
      [dip_buy, _held] = Strategies.recipes()
      [nas, spx] = dip_buy.assignments

      assert %{status: :passed, stats: %{"num_trades" => 118}} = nas.results.backtest

      assert %{status: :failed, reason: "out-of-sample Sharpe below 0.05"} =
               nas.results.walk_forward

      assert nas.results.monte_carlo.reason ==
               "Skipped because the walk-forward test failed."

      assert %{trades: 1, wins: 1, pnl: 84.44} = nas.results.live

      assert spx.results.backtest.reason == "Never run through the testing pipeline."
      assert spx.results.live == %{trades: 0}
    end
  end
end
