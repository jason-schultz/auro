defmodule Opus.Pipeline.StuckTest do
  use Opus.DataCase, async: false
  use Oban.Testing, repo: Opus.Repo

  import Ecto.Query

  alias Opus.Dashboard
  alias Opus.Instruments

  alias Opus.Pipeline.{
    BacktestWorker,
    HoldoutWorker,
    StrategyConfig,
    StrategyEvaluation,
    Stuck,
    WalkForwardWorker
  }

  alias Opus.Trading.{Recipe, StrategyResults}

  @definition %{
    "strategy_name" => "Dip-buy",
    "components" => %{"r" => %{"type" => "Rsi", "params" => %{"period" => 2}}},
    "entry" => %{"long" => "r.oversold"},
    "exit" => %{"long" => "r.overbought"},
    "stop" => %{"type" => "FixedPct", "params" => %{"pct" => -0.02}}
  }

  setup do
    {:ok, _} = Instruments.add("SPX500_USD", "index")
    :ok
  end

  # A run by today's rules: `results` is `[{stage, status}]`; a `running`
  # row was started `started_ago` seconds ago.
  defp run!(results, opts \\ []) do
    config =
      %StrategyConfig{}
      |> StrategyConfig.changeset(%{
        instrument: "SPX500_USD",
        granularity: "H4",
        strategy_type: "composite",
        parameters: Map.merge(@definition, %{"instrument" => "SPX500_USD", "granularity" => "H4"})
      })
      |> Repo.insert!()

    if opts[:archived],
      do:
        Repo.update_all(from(c in StrategyConfig, where: c.id == ^config.id),
          set: [archived_at: DateTime.utc_now()]
        )

    started = DateTime.add(DateTime.utc_now(), -Keyword.get(opts, :started_ago, 0))

    for {stage, status} <- results do
      Repo.insert!(%StrategyEvaluation{
        strategy_config_id: config.id,
        stage: stage,
        status: status,
        evaluated_at: if(status in ~w(passed failed), do: DateTime.utc_now()),
        rules_version: if(status in ~w(passed failed), do: StrategyEvaluation.rules_version()),
        stats: if(status in ~w(passed failed), do: %{"checks" => []}),
        inserted_at: started,
        updated_at: started
      })
    end

    config
  end

  defp passed(stages), do: Enum.map(stages, &{&1, "passed"})

  defp stages(config),
    do: StrategyResults.for_configs([{config.id, config.inserted_at}]) |> Map.fetch!(config.id)

  defp enqueue!(worker, config, opts \\ []) do
    {:ok, job} = Oban.insert(worker.new(%{config_id: config.id}, opts))
    job
  end

  describe "detection" do
    test "the next stage with no job behind it is stuck; queued or snoozed, it waits" do
      config = run!(passed(~w(backtest)))
      assert %{status: :stuck, stage: :walk_forward, started: false} = stages(config).walk_forward
      # The stage after it isn't stuck too: it waits on this one.
      assert stages(config).monte_carlo.status == :not_run

      job = enqueue!(WalkForwardWorker, config)
      assert stages(config).walk_forward.status == :pending

      # A snoozed job (waiting for the tester) is scheduled: still waiting.
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "scheduled", scheduled_at: DateTime.add(DateTime.utc_now(), 60)]
      )

      assert stages(config).walk_forward.status == :pending

      # Cleared from the dashboard, or discarded: nothing will run it.
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "discarded"])
      assert stages(config).walk_forward.status == :stuck
    end

    test "a submitted run waits for its backtest job; with the job gone it's stuck" do
      config = run!([])
      job = enqueue!(BacktestWorker, config)
      assert stages(config).backtest.status == :pending

      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "cancelled"])
      assert %{status: :stuck, stage: :backtest} = stages(config).backtest
    end

    test "a running row counts as running within its stage's window, stuck after it" do
      fresh = run!(passed(~w(backtest)) ++ [{"walk_forward", "running"}], started_ago: 60)
      assert stages(fresh).walk_forward.status == :running

      stale = run!(passed(~w(backtest)) ++ [{"walk_forward", "running"}], started_ago: 20 * 60)
      assert %{status: :stuck, started: true} = stages(stale).walk_forward

      # The nearby-settings test runs longer and has a longer window.
      slow =
        run!(
          passed(~w(backtest walk_forward monte_carlo)) ++ [{"parameter_stability", "running"}],
          started_ago: 20 * 60
        )

      assert stages(slow).parameter_stability.status == :running

      # An old running row with its job executing is running, whatever its age.
      enqueue!(WalkForwardWorker, stale)

      Repo.update_all(from(j in Oban.Job, where: j.args["config_id"] == ^stale.id),
        set: [state: "executing"]
      )

      assert stages(stale).walk_forward.status == :running
    end

    test "finished runs have nothing stuck" do
      failed = run!([{"backtest", "failed"}])
      done = run!(passed(~w(backtest walk_forward monte_carlo parameter_stability holdout)))

      for config <- [failed, done], {_stage, result} <- stages(config) do
        refute result.status == :stuck
      end
    end
  end

  describe "resume/3" do
    test "enqueues the stuck stage's worker once" do
      config = run!(passed(~w(backtest)))

      assert {:ok, %Oban.Job{}} = Stuck.resume(config.id, "walk_forward")
      assert_enqueued(worker: WalkForwardWorker, args: %{config_id: config.id})
      assert stages(config).walk_forward.status == :pending

      # Now something is going to run it: a second click does nothing.
      assert Stuck.resume(config.id, "walk_forward") == {:error, :not_stuck}
      assert [_one] = all_enqueued(worker: WalkForwardWorker)
    end

    test "re-runs a stage that started and died" do
      config = run!(passed(~w(backtest)) ++ [{"walk_forward", "running"}], started_ago: 20 * 60)
      assert {:ok, _job} = Stuck.resume(config.id, "walk_forward")
      assert_enqueued(worker: WalkForwardWorker, args: %{config_id: config.id})
    end

    test "never re-runs a stage with a result, nor one whose stage before hasn't passed" do
      config = run!(passed(~w(backtest)))

      assert Stuck.resume(config.id, "backtest") == {:error, :not_stuck}
      assert Stuck.resume(config.id, "monte_carlo") == {:error, :not_stuck}
      assert Stuck.resume(config.id, "nonsense") == {:error, :not_stuck}
      assert Stuck.resume(Ecto.UUID.generate(), "backtest") == {:error, :not_found}
      refute_enqueued(worker: BacktestWorker)
      refute_enqueued(worker: WalkForwardWorker)
    end

    test "the holdout only resumes when the one-time look is confirmed" do
      config = run!(passed(~w(backtest walk_forward monte_carlo parameter_stability)))
      assert %{status: :stuck, stage: :holdout} = stages(config).holdout

      assert Stuck.resume(config.id, "holdout") == {:error, :holdout_needs_confirm}
      refute_enqueued(worker: HoldoutWorker)

      assert {:ok, _job} = Stuck.resume(config.id, "holdout", holdout: :confirmed)
      assert_enqueued(worker: HoldoutWorker, args: %{config_id: config.id})
    end

    test "an archived run isn't resumed" do
      config = run!(passed(~w(backtest)), archived: true)
      assert Stuck.resume(config.id, "walk_forward") == {:error, :archived}
      refute_enqueued(worker: WalkForwardWorker)
    end
  end

  describe "reporting" do
    test "lists stuck runs that aren't archived, with the strategy that has their rules" do
      recipe =
        Repo.insert!(%Recipe{name: "Dip-buy", granularity: "H4", definition: @definition})

      stuck = run!(passed(~w(backtest walk_forward)))
      run!(passed(~w(backtest)), archived: true)
      enqueue!(WalkForwardWorker, run!(passed(~w(backtest))))
      run!([{"backtest", "failed"}])

      assert [run] = Stuck.list()

      assert run == %{
               config_id: stuck.id,
               instrument: "SPX500_USD",
               granularity: "H4",
               name: "Dip-buy",
               basket: false,
               stage: :monte_carlo,
               started: false,
               recipe_id: recipe.id
             }
    end

    test "the dashboard reports a stuck run as check-soon and resumes nothing" do
      recipe =
        Repo.insert!(%Recipe{name: "Dip-buy", granularity: "H4", definition: @definition})

      config = run!(passed(~w(backtest walk_forward monte_carlo parameter_stability)))

      alerts = Dashboard.gather() |> Map.fetch!(:input) |> Dashboard.alerts()
      key = "stuck_run:#{config.id}:holdout"

      assert %{level: :check, title: title, what_to_do: what_to_do, link: link} =
               Enum.find(alerts, &(&1.key == key))

      assert title == "Dip-buy's test stopped at the holdout"
      assert what_to_do =~ "one-time look"
      assert link == "/strategies/recipes/#{recipe.id}/edit"

      # Act-now alerts stay first.
      levels = Enum.map(alerts, & &1.level)

      assert levels ==
               Enum.sort_by(levels, &Enum.find_index([:act, :check, :fyi], fn l -> l == &1 end))

      refute_enqueued(worker: HoldoutWorker)
      assert stages(config).holdout.status == :stuck
    end

    test "nothing stuck, no alert" do
      config = run!(passed(~w(backtest)))
      enqueue!(WalkForwardWorker, config)
      assert Stuck.list() == []
    end
  end
end
