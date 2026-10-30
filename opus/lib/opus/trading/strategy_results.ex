defmodule Opus.Trading.StrategyResults do
  @moduledoc """
  What's known about how each assigned strategy performs: the validation
  pipeline's backtest, walk-forward, Monte Carlo, parameter-stability and
  holdout stages, and its live (forward-test) trades on OANDA.

  A pipeline run is matched to an assignment by instrument, timeframe and
  settings (`Strategies.trade_settings/1`): names, version and sizing don't
  count, the same match Squad and the engine's luck check use. Every stage comes
  back with a status, and a stage that has no numbers says why
  (`:reason`), so the page never shows a bare blank. A stage that looks
  waiting or running with nothing working on it is `:stuck`, with the
  `config_id` and `stage` to resume it from (`Opus.Pipeline.Stuck`).
  """

  import Ecto.Query

  alias Opus.Pipeline.{StrategyConfig, StrategyEvaluation, Stuck}
  alias Opus.Repo
  alias Opus.Trading.{LiveStrategy, Strategies}

  @stages ~w(backtest walk_forward monte_carlo parameter_stability holdout)
  # Database strings to atoms by explicit mapping, never String.to_atom.
  @stage_keys Map.new(@stages, &{&1, String.to_atom(&1)})
  @statuses %{
    "pending" => :pending,
    "running" => :running,
    "passed" => :passed,
    "failed" => :failed
  }

  # The engine's failure text for one rule, and its operators in words.
  @failure ~r/^(\w+): (-?\d+\.\d+) (is below minimum|must be greater than|is above maximum|must be less than) (-?\d+\.\d+)$/
  @operators %{
    "is below minimum" => "gte",
    "must be greater than" => "gt",
    "is above maximum" => "lte",
    "must be less than" => "lt"
  }

  # When the holdout and parameter-stability stages joined the pipeline.
  # Runs from before a stage joined have no row for it; runs from before
  # parameter stability went straight from Monte Carlo to the holdout.
  @holdout_added ~U[2026-10-17 16:31:00Z]
  @stability_added ~U[2026-10-30 01:30:00Z]
  @previous %{
    "walk_forward" => "backtest",
    "monte_carlo" => "walk_forward",
    "parameter_stability" => "monte_carlo",
    "holdout" => "parameter_stability"
  }

  # `old`, on a finished stage: judged by earlier rules than today's (its
  # rules version, `StrategyEvaluation.current?/1`), so it must be re-tested
  # before it counts. An old pass reads as `:old_pass`, an old fail as
  # `:old_fail`.
  @type stage :: %{
          optional(:old) => boolean(),
          status: atom(),
          stats: map() | nil,
          reason: String.t() | nil,
          at: term()
        }
  @type t :: %{
          backtest: stage(),
          walk_forward: stage(),
          monte_carlo: stage(),
          parameter_stability: stage(),
          holdout: stage(),
          live: map()
        }

  @doc "Results for each assignment id."
  @spec for_ids([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => t()}
  def for_ids(ids) do
    configs = latest_configs(ids)
    known = configs |> Map.values() |> Enum.map(&elem(&1, 0)) |> known()
    live = live(ids)

    Map.new(ids, fn id ->
      run =
        case configs[id] do
          {config_id, ran_at} -> {config_id, ran_at}
          nil -> nil
        end

      {id, run |> stages(known) |> Map.put(:live, Map.get(live, id, %{trades: 0}))}
    end)
  end

  @doc """
  Test runs of a recipe that isn't assigned anywhere yet, one per
  instrument it was tested on (the newest): `%{instrument, ran_at, archived,
  stages}` with `stages` shaped as in `for_ids/1`; `archived` is a run from
  before the block builder, which pages hide unless asked. Matched by the
  recipe's settings on the recipe's timeframe (the same rules on another
  timeframe are a different test).
  """
  @spec for_recipe(map(), String.t()) :: [map()]
  def for_recipe(definition, granularity),
    do: [{definition, granularity}] |> for_recipes() |> hd()

  @doc """
  `for_recipe/2` for several recipes, `[{definition, granularity}]`, in one
  load: a list of their results in the same order.
  """
  @spec for_recipes([{map(), String.t()}]) :: [[map()]]
  def for_recipes([]), do: []

  def for_recipes(recipes) do
    granularities = recipes |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    by_settings =
      from(sc in StrategyConfig,
        where:
          sc.granularity in ^granularities and
            not fragment("jsonb_exists(?, 'basket')", sc.parameters),
        order_by: [asc: sc.instrument, desc: sc.inserted_at],
        select: %{
          instrument: sc.instrument,
          granularity: sc.granularity,
          id: sc.id,
          ran_at: sc.inserted_at,
          archived: not is_nil(sc.archived_at),
          parameters: sc.parameters
        }
      )
      |> Repo.all()
      |> Enum.group_by(&{&1.granularity, Strategies.trade_settings(&1.parameters)})

    runs =
      Enum.map(recipes, fn {definition, granularity} ->
        by_settings
        |> Map.get({granularity, Strategies.trade_settings(definition)}, [])
        |> Enum.uniq_by(& &1.instrument)
      end)

    known = runs |> List.flatten() |> Enum.map(& &1.id) |> Enum.uniq() |> known()

    Enum.map(runs, fn configs ->
      Enum.map(configs, fn %{instrument: instrument, id: id, ran_at: ran_at, archived: archived} ->
        %{
          instrument: instrument,
          ran_at: ran_at,
          archived: archived,
          stages: stages({id, ran_at}, known)
        }
      end)
    end)
  end

  @doc """
  The stages of pipeline runs by config id, each run given as `{config_id,
  ran_at}`, shaped as in `for_ids/1` (without `:live`).
  """
  @spec for_configs([{Ecto.UUID.t(), DateTime.t()}]) :: %{Ecto.UUID.t() => map()}
  def for_configs(runs) do
    known = runs |> Enum.map(&elem(&1, 0)) |> known()
    Map.new(runs, fn {id, ran_at} -> {id, stages({id, ran_at}, known)} end)
  end

  @doc """
  Basket test runs of a recipe (several markets as one account,
  `Opus.Trading.Baskets`), newest first: `%{config_id, ran_at, basket,
  stages}` with `basket` the stored settings (`"markets"`, `"mode"`,
  `"rank"`) and `stages` shaped as in `for_ids/1`. Matched like
  `for_recipe/2`.
  """
  @spec for_baskets(map(), String.t()) :: [map()]
  def for_baskets(definition, granularity) do
    configs =
      from(sc in StrategyConfig,
        where:
          sc.granularity == ^granularity and fragment("jsonb_exists(?, 'basket')", sc.parameters),
        order_by: [desc: sc.inserted_at],
        select: %{id: sc.id, ran_at: sc.inserted_at, parameters: sc.parameters}
      )
      |> Repo.all()
      |> same_settings(definition)

    known = configs |> Enum.map(& &1.id) |> known()

    Enum.map(configs, fn %{id: id, ran_at: ran_at, parameters: parameters} ->
      %{
        config_id: id,
        ran_at: ran_at,
        basket: parameters["basket"],
        stages: stages({id, ran_at}, known)
      }
    end)
  end

  # The five pipeline stages of one run, `{config_id, ran_at}`, or nil
  # when the assignment has never been through the pipeline. A stage with
  # no row yet is waiting when the one before it passed (or it's the
  # backtest); runs from before the holdout stage existed have none. A
  # waiting or running stage with nothing working on it is stuck
  # (`Opus.Pipeline.Stuck`).
  defp stages(nil, _known) do
    Map.new(@stages, fn stage ->
      {@stage_keys[stage], not_run("Never run through the testing pipeline.")}
    end)
  end

  defp stages({config_id, ran_at}, known) do
    by_stage = Map.get(known.evaluations, config_id, %{})

    run = %{
      config_id: config_id,
      jobs: known.jobs,
      now: known.now,
      archived: MapSet.member?(known.archived, config_id)
    }

    Map.new(@stages, &{@stage_keys[&1], stage(&1, ran_at, by_stage, run)})
  end

  defp stage(stage, ran_at, by_stage, run) do
    previous = previous(stage, ran_at)

    case {by_stage[stage], by_stage[previous]} do
      # A pass judged by earlier rules (stamped with an older rules version,
      # or none) reads as that, not as meeting today's standard.
      {%{status: "passed"} = e, _previous} ->
        if StrategyEvaluation.current?(e),
          do: finished(e),
          else: %{
            status: :old_pass,
            stats: e.stats,
            at: e.evaluated_at,
            reason:
              "Passed the rules in use when it ran and hasn't been re-run since. Re-test it to judge it by today's standard.",
            checks: checks(e.stats, nil),
            old: true
          }

      {%{status: status} = e, _previous} when status in ["pending", "running"] ->
        if stuck?(stage, e, run),
          do: stuck(stage, e, run),
          else: %{
            status: Map.fetch!(@statuses, status),
            stats: nil,
            at: nil,
            reason: nil,
            checks: []
          }

      # Likewise a fail: today's rules might judge it differently.
      {%{status: "failed"} = e, _previous} ->
        if StrategyEvaluation.current?(e),
          do: finished(e),
          else: %{
            status: :old_fail,
            stats: e.stats,
            at: e.evaluated_at,
            reason:
              "Failed the rules in use when it ran and hasn't been re-run since. Re-test it to judge it by today's standard.",
            checks: checks(e.stats, e.failure_reason),
            old: true
          }

      {%{} = e, _previous} ->
        finished(e)

      {nil, %{status: "failed"}} ->
        not_run("Skipped because the #{words(previous)} failed.")

      {nil, %{status: "passed"}} when stage == "parameter_stability" ->
        if before?(ran_at, @stability_added),
          do:
            not_run(
              "Not run. The nearby-settings test joined the pipeline on Oct 30, after this ran. " <>
                "Re-test it to include it."
            ),
          else: waiting(stage, run)

      {nil, %{status: "passed"}} when stage == "holdout" ->
        if before?(ran_at, @holdout_added),
          do:
            not_run(
              "Not run. It's a one-time look at data kept aside; tests run since Oct 17 " <>
                "include it after Monte Carlo, and these ran before that."
            ),
          else: waiting(stage, run)

      {nil, %{status: "passed"}} ->
        waiting(stage, run)

      # The stage before is still running (or stuck itself): this one waits on it.
      {nil, %{status: _running}} ->
        waiting()

      {nil, nil} when stage == "backtest" ->
        waiting(stage, run)

      {nil, nil} ->
        not_run("Not run.")
    end
  end

  # A finished stage (passed or failed) as recorded; `old` when it was
  # judged by earlier rules (`StrategyEvaluation.current?/1`).
  defp finished(e) do
    %{
      status: Map.fetch!(@statuses, e.status),
      stats: e.stats,
      at: e.evaluated_at,
      reason: if(e.status == "failed", do: e.failure_reason),
      checks: checks(e.stats, e.failure_reason),
      old: not StrategyEvaluation.current?(e)
    }
  end

  # The stage a run reached this one from: before parameter stability
  # joined, the holdout followed Monte Carlo.
  defp previous("holdout", ran_at) do
    if before?(ran_at, @stability_added), do: "monte_carlo", else: @previous["holdout"]
  end

  defp previous(stage, _ran_at), do: @previous[stage]

  defp before?(ran_at, added), do: DateTime.compare(ran_at, added) == :lt

  defp waiting, do: %{status: :pending, stats: nil, at: nil, reason: nil, checks: []}

  # Waiting for its job, or stuck when there is none.
  defp waiting(stage, run),
    do: if(stuck?(stage, nil, run), do: stuck(stage, nil, run), else: waiting())

  defp stuck?(stage, evaluation, run),
    do: Stuck.stuck?(run.config_id, stage, evaluation, run.jobs, run.now)

  # `config_id` and `stage` say what `Stuck.resume/3` would pick up;
  # `started` whether the stage had begun (a `running` row). An archived
  # run is never resumed (`Stuck.resume/3`), so it just never finished.
  defp stuck(_stage, _evaluation, %{archived: true}),
    do: not_run("Never finished: the run was archived first. Re-test it to finish it.")

  defp stuck(stage, evaluation, run) do
    %{
      status: :stuck,
      stats: nil,
      at: nil,
      reason:
        "Stopped part-way (the tester restarted or the job was cleared): nothing is running it.",
      checks: [],
      config_id: run.config_id,
      stage: @stage_keys[stage],
      started: evaluation != nil
    }
  end

  defp not_run(reason), do: %{status: :not_run, stats: nil, at: nil, reason: reason, checks: []}

  @doc """
  The rules a stage was judged on, `%{metric, operator, required, actual,
  passed}`: what the engine recorded (`stats["checks"]`, since Oct 28), or
  for older runs the failed ones read back out of the failure text
  (`"oos_sharpe: -0.1326 is below minimum 0.0800"`).
  """
  @spec checks(map() | nil, String.t() | nil) :: [map()]
  def checks(%{"checks" => checks}, _reason) when is_list(checks),
    do:
      Enum.map(checks, fn c ->
        %{
          metric: c["metric"],
          operator: c["operator"],
          required: c["required"],
          actual: c["actual"],
          passed: c["passed"]
        }
      end)

  def checks(_stats, reason) when is_binary(reason) do
    reason
    |> String.split("; ")
    |> Enum.flat_map(fn part ->
      case Regex.run(@failure, part) do
        [_, metric, actual, words, required] ->
          [
            %{
              metric: metric,
              operator: Map.fetch!(@operators, words),
              required: String.to_float(required),
              actual: String.to_float(actual),
              passed: false
            }
          ]

        nil ->
          []
      end
    end)
  end

  def checks(_stats, _reason), do: []

  defp words("backtest"), do: "backtest"
  defp words("walk_forward"), do: "walk-forward test"
  defp words("monte_carlo"), do: "Monte Carlo test"
  defp words("parameter_stability"), do: "nearby-settings test"

  # Newest pipeline run per assignment: assignment id => config id.
  # Each assignment's newest run of its own settings on its instrument and
  # timeframe.
  defp latest_configs(ids) do
    assigned =
      from(ls in LiveStrategy,
        where: ls.id in ^ids,
        select: %{id: ls.id, market: {ls.instrument, ls.granularity}, parameters: ls.parameters}
      )
      |> Repo.all()

    instruments = assigned |> Enum.map(&elem(&1.market, 0)) |> Enum.uniq()

    runs =
      from(sc in StrategyConfig,
        where:
          sc.instrument in ^instruments and
            not fragment("jsonb_exists(?, 'basket')", sc.parameters),
        order_by: [desc: sc.inserted_at],
        select: %{
          id: sc.id,
          ran_at: sc.inserted_at,
          market: {sc.instrument, sc.granularity},
          parameters: sc.parameters
        }
      )
      |> Repo.all()
      |> Enum.group_by(& &1.market)

    for a <- assigned,
        run = runs |> Map.get(a.market, []) |> same_settings(a.parameters) |> List.first(),
        run != nil,
        into: %{},
        do: {a.id, {run.id, run.ran_at}}
  end

  # The runs of the same strategy as `parameters`: the same settings,
  # whatever their names, version or sizing. Order is kept.
  defp same_settings(runs, parameters) do
    settings = Strategies.trade_settings(parameters)
    Enum.filter(runs, &(Strategies.trade_settings(&1.parameters) == settings))
  end

  # What shaping a set of runs needs: their evaluation rows by stage, the
  # stages with a live job, and one clock for all of them.
  defp known(config_ids) do
    %{
      evaluations: evaluations(config_ids),
      jobs: Stuck.live_jobs(config_ids),
      now: DateTime.utc_now(),
      archived: archived(config_ids)
    }
  end

  defp archived([]), do: MapSet.new()

  defp archived(config_ids) do
    from(c in StrategyConfig,
      where: c.id in ^config_ids and not is_nil(c.archived_at),
      select: c.id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp evaluations([]), do: %{}

  defp evaluations(config_ids) do
    from(e in StrategyEvaluation, where: e.strategy_config_id in ^config_ids)
    |> Repo.all()
    |> Enum.group_by(& &1.strategy_config_id)
    |> Map.new(fn {config_id, evals} -> {config_id, Map.new(evals, &{&1.stage, &1})} end)
  end

  # Closed live trades per assignment: count, wins, profit in CAD, first entry.
  defp live(ids) do
    from(t in "live_trades",
      where: t.status == "closed" and t.live_strategy_id in type(^ids, {:array, Ecto.UUID}),
      group_by: t.live_strategy_id,
      select:
        {type(t.live_strategy_id, Ecto.UUID),
         %{
           trades: count(t.id),
           wins: fragment("COUNT(*) FILTER (WHERE ? > 0)::int", t.pnl),
           pnl: fragment("COALESCE(SUM(?), 0)::float8", t.pnl),
           since: type(min(t.entry_time), :utc_datetime_usec)
         }}
    )
    |> Repo.all()
    |> Map.new()
  end
end
