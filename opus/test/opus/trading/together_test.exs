defmodule Opus.Trading.TogetherTest do
  # Not async: the promote test points the engine's address at a stand-in.
  use Opus.DataCase, async: false
  use Oban.Testing, repo: Opus.Repo

  alias Opus.Instruments

  alias Opus.Pipeline.{
    BacktestWorker,
    ParameterStabilityWorker,
    StrategyConfig,
    StrategyEvaluation
  }

  alias Opus.Trading.{LiveStrategy, Recipe, StrategyResults, Together}

  @stages ~w(backtest walk_forward monte_carlo parameter_stability holdout)

  # A stand-in engine: answers `path` with 200 and `body`, anything else 404.
  defmodule Engine do
    @behaviour Plug

    @impl true
    def init(answer), do: answer

    @impl true
    def call(%Plug.Conn{request_path: path} = conn, {path, body}) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    def call(conn, _answer), do: Plug.Conn.send_resp(conn, 404, "")
  end

  # config/test.exs points the live engine at a closed port; for one test,
  # point it at a stand-in instead.
  defp engine_answers(path, body) do
    pid =
      start_supervised!(
        {Bandit, plug: {Engine, {path, body}}, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    previous = Application.fetch_env!(:opus, :auro_base_url)
    on_exit(fn -> Application.put_env(:opus, :auro_base_url, previous) end)
    Application.put_env(:opus, :auro_base_url, "http://127.0.0.1:#{port}")
  end

  setup do
    for i <- ~w(SPX500_USD EU50_EUR), do: {:ok, _} = Instruments.add(i, "index")
    :ok
  end

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        "strategy_name" => "Dip-buy",
        "version" => "1",
        "instrument" => "SPX500_USD",
        "granularity" => "H4",
        "components" => %{"r" => %{"type" => "Rsi", "params" => %{"period" => 2}}},
        "entry" => %{"long" => "r.oversold"},
        "exit" => %{"long" => "r.overbought"},
        "stop" => %{"type" => "FixedPct", "params" => %{"pct" => -0.02}},
        "sizing" => %{"type" => "RiskPct", "params" => %{"pct" => 0.01}}
      },
      overrides
    )
  end

  # A pipeline run: `results` is `[{stage, status}]` in order; by today's
  # rules each result records its checks, an old run's don't.
  defp run!(parameters, results, opts \\ []) do
    config =
      %StrategyConfig{}
      |> StrategyConfig.changeset(%{
        instrument: parameters["instrument"],
        granularity: parameters["granularity"],
        strategy_type: "composite",
        parameters: parameters
      })
      |> Repo.insert!()

    at = opts |> Keyword.get(:at, DateTime.utc_now()) |> DateTime.add(0, :microsecond)
    # `old: true`: judged before results were stamped (no rules version,
    # no checks recorded); `rules_version:` stamps another version.
    old = Keyword.get(opts, :old, false)

    version =
      if old, do: nil, else: Keyword.get(opts, :rules_version, StrategyEvaluation.rules_version())

    from(c in StrategyConfig, where: c.id == ^config.id)
    |> Repo.update_all(set: [inserted_at: at, archived_at: if(opts[:archived], do: at)])

    for {stage, status} <- results do
      failed = status == "failed"

      Repo.insert!(%StrategyEvaluation{
        strategy_config_id: config.id,
        stage: stage,
        status: status,
        evaluated_at: if(status in ~w(passed failed), do: at),
        rules_version: if(status in ~w(passed failed), do: version),
        failure_reason: if(failed, do: "p95_drawdown: 0.3100 is above maximum 0.2500"),
        stats:
          cond do
            status not in ~w(passed failed) ->
              nil

            old ->
              %{"p95_drawdown" => 0.31}

            true ->
              %{
                "checks" => [
                  %{
                    "metric" => "p95_drawdown",
                    "operator" => "lte",
                    "required" => 0.25,
                    "actual" => if(failed, do: 0.31, else: 0.2),
                    "passed" => !failed
                  }
                ]
              }
          end
      })
    end

    config
  end

  defp passed(n), do: @stages |> Enum.take(n) |> Enum.map(&{&1, "passed"})

  defp tested, do: Together.choices().tested

  describe "one row per play" do
    test "configs of the same strategy show once, ignoring name, sizing, version and recipe id" do
      run!(params(), passed(2), at: ~U[2026-10-30 03:00:00Z])

      run!(
        params(%{
          "strategy_name" => "Renamed",
          "version" => "2",
          "strategy_id" => Ecto.UUID.generate(),
          "sizing" => %{"type" => "RiskPct", "params" => %{"pct" => 0.02}},
          # 2.0 and 2 are the same setting; a null hold limit is no limit.
          "components" => %{"r" => %{"type" => "Rsi", "params" => %{"period" => 2.0}}},
          "max_hold_bars" => nil
        }),
        passed(2),
        at: ~U[2026-10-30 04:00:00Z]
      )

      assert [%{name: "Renamed"}] = tested()
    end

    test "plays that look alike say which settings tell them apart" do
      run!(params(), passed(2))

      run!(
        params(%{"components" => %{"r" => %{"type" => "Rsi", "params" => %{"period" => 3}}}}),
        passed(2)
      )

      run!(params(%{"strategy_name" => "Other"}) |> Map.put("instrument", "EU50_EUR"), passed(2))

      assert tested() |> Enum.map(&{&1.instrument, &1.variant}) |> Enum.sort() == [
               {"EU50_EUR", nil},
               {"SPX500_USD", "r period 2"},
               {"SPX500_USD", "r period 3"}
             ]
    end

    test "other settings, timeframe or instrument are other plays" do
      run!(params(), passed(2))

      run!(
        params(%{"components" => %{"r" => %{"type" => "Rsi", "params" => %{"period" => 3}}}}),
        passed(2)
      )

      run!(params(%{"granularity" => "D"}), passed(2))
      run!(params(%{"instrument" => "EU50_EUR"}), passed(2))

      assert length(tested()) == 4
    end

    test "a run by today's rules wins over a newer old one, and shows even before its walk-forward" do
      run!(params(), passed(2), at: ~U[2026-10-30 08:00:00Z], archived: true)
      current = run!(params(), [{"backtest", "running"}], at: ~U[2026-10-30 03:00:00Z])

      assert [%{config_id: id, status: {:testing, :backtest}, old: false}] = tested()
      assert id == current.id
    end

    test "a strategy that never passed a walk-forward isn't offered" do
      run!(params(), [{"backtest", "passed"}, {"walk_forward", "failed"}])
      assert tested() == []
    end

    test "a strategy you already have is left out of the tested plays" do
      definition = Map.drop(params(), ~w(instrument granularity sizing))

      recipe =
        Repo.insert!(%Recipe{name: "Dip-buy", granularity: "H4", definition: definition})

      now = DateTime.utc_now()

      Repo.insert!(%LiveStrategy{
        strategy_type: "composite",
        instrument: "SPX500_USD",
        granularity: "H4",
        parameters: params(),
        strategy_id: recipe.id,
        enabled: false,
        created_at: now,
        updated_at: now
      })

      run!(params(%{"strategy_name" => "Old name"}), passed(5))

      assert %{yours: [%{status: :switched_off} = mine], tested: []} = Together.choices()
      assert Together.next_step(mine) == :open
    end
  end

  describe "where a play stands" do
    test "passed every test, the holdout too: ready, and the next step is to add it" do
      run!(params(), passed(5))
      assert [%{status: :ready} = play] = tested()
      assert Together.next_step(play) == :promote
    end

    test "failed a stage by today's rules: that stage with its result, and no next step" do
      run!(params(), passed(2) ++ [{"monte_carlo", "failed"}])

      assert [%{status: {:failed, :monte_carlo, result}} = play] = tested()
      assert [%{metric: "p95_drawdown", passed: false}] = result.checks
      assert Together.next_step(play) == nil
    end

    test "a stage still to run: still testing, no next step" do
      config = run!(params(), passed(3))
      {:ok, _job} = Oban.insert(ParameterStabilityWorker.new(%{config_id: config.id}))

      assert [%{status: {:testing, :parameter_stability}} = play] = tested()
      assert Together.next_step(play) == nil
    end

    test "a stage nothing is going to run: stuck, and the next step is to resume it" do
      run!(params(), passed(3))
      assert [%{status: {:stuck, :parameter_stability}} = play] = tested()
      assert Together.next_step(play) == :resume
    end

    test "archived: old, whatever it passed, and the next step is a re-test" do
      run!(params(), passed(5), archived: true)
      assert [%{status: :old, old: true} = play] = tested()
      assert Together.next_step(play) == :retest
    end

    test "an archived run left part-way never finished: no stuck stage to resume" do
      config = run!(params(), passed(2), archived: true)

      %{monte_carlo: stage} =
        StrategyResults.for_configs([{config.id, config.inserted_at}])[config.id]

      assert %{status: :not_run, reason: "Never finished" <> _} = stage
    end

    test "a play remembers if any run of it was judged on the holdout already" do
      run!(params(), passed(5), archived: true)
      assert [%{holdout_seen: true}] = tested()
    end

    test "a play that never reached the holdout hasn't seen it" do
      run!(params(), passed(2) ++ [{"monte_carlo", "failed"}], archived: true)
      assert [%{holdout_seen: false}] = tested()
    end

    test "a run judged before results were stamped with a rules version: old" do
      run!(params(), passed(2) ++ [{"monte_carlo", "failed"}], old: true)
      assert [%{status: :old}] = tested()
    end

    test "a run judged by an earlier rules version: old, its fail included" do
      earlier = StrategyEvaluation.rules_version() - 1
      run!(params(), passed(2) ++ [{"monte_carlo", "failed"}], rules_version: earlier)
      assert [%{status: :old} = play] = tested()
      assert Together.next_step(play) == :retest
    end

    test "one stage judged by earlier rules makes the whole run old" do
      config = run!(params(), passed(5))

      from(e in StrategyEvaluation,
        where: e.strategy_config_id == ^config.id and e.stage == "backtest"
      )
      |> Repo.update_all(set: [rules_version: nil])

      assert [%{status: :old}] = tested()
    end

    test "a run from before a stage joined the pipeline is old" do
      # Before the nearby-settings test (Oct 30): Monte Carlo went straight
      # to the holdout, so it never ran.
      run!(params(), passed(3) ++ [{"holdout", "passed"}], at: ~U[2026-10-29 12:00:00Z])
      assert [%{status: :old}] = tested()
    end

    test "your strategies: switched on is trading, with nothing to do here" do
      recipe = Repo.insert!(%Recipe{name: "On", granularity: "D", definition: %{}})
      now = DateTime.utc_now()

      Repo.insert!(%LiveStrategy{
        strategy_type: "composite",
        instrument: "SPX500_USD",
        granularity: "D",
        parameters: %{},
        strategy_id: recipe.id,
        enabled: true,
        created_at: now,
        updated_at: now
      })

      assert %{yours: [%{status: :trading} = play]} = Together.choices()
      assert Together.next_step(play) == nil
    end
  end

  describe "next steps" do
    test "a re-test sends the same strategy through as a new run; the old one stays" do
      old = run!(params(), passed(2), archived: true)
      [%{key: key}] = tested()

      assert {:ok, %StrategyConfig{} = new} = Together.retest(key)
      assert new.id != old.id
      assert new.parameters == old.parameters
      assert new.instrument == "SPX500_USD" and new.granularity == "H4"
      assert_enqueued(worker: BacktestWorker, args: %{config_id: new.id})
      assert Repo.get(StrategyConfig, old.id)

      # The play is now the new run, waiting for its backtest.
      assert [%{config_id: id, status: {:testing, :backtest}}] = tested()
      assert id == new.id
    end

    test "only an old play can be re-tested" do
      run!(params(), passed(5))
      [%{key: key}] = tested()

      assert Together.retest(key) == {:error, :not_old}
      refute_enqueued(worker: BacktestWorker)
    end

    test "a ready play is added to live through the engine" do
      engine_answers("/api/live/strategies", %{"id" => Ecto.UUID.generate(), "enabled" => false})
      run!(params(), passed(5))
      [%{key: key}] = tested()

      assert Together.promote(key) == {:ok, :promoted}
    end

    test "a play that isn't ready isn't added to live" do
      run!(params(), passed(5), archived: true)
      [%{key: key}] = tested()

      assert Together.promote(key) == {:error, :not_ready}
      assert Together.promote("live:#{Ecto.UUID.generate()}") == {:error, :not_ready}
    end
  end
end
