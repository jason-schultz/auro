defmodule Opus.Trading.StrategyResults do
  @moduledoc """
  What's known about how each assigned strategy performs: the validation
  pipeline's backtest, walk-forward, Monte Carlo and holdout stages, and
  its live (forward-test) trades on OANDA.

  A pipeline run is matched to an assignment by instrument and the exact
  strategy JSON, the same match Rust uses for its stats. Every stage comes
  back with a status, and a stage that has no numbers says why
  (`:reason`), so the page never shows a bare blank.
  """

  import Ecto.Query

  alias Opus.Pipeline.{StrategyConfig, StrategyEvaluation}
  alias Opus.Repo
  alias Opus.Trading.LiveStrategy

  @stages ~w(backtest walk_forward monte_carlo holdout)
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

  # When the holdout stage joined the pipeline.
  @holdout_added ~U[2026-10-17 16:31:00Z]
  @previous %{
    "walk_forward" => "backtest",
    "monte_carlo" => "walk_forward",
    "holdout" => "monte_carlo"
  }

  @type stage :: %{status: atom(), stats: map() | nil, reason: String.t() | nil, at: term()}
  @type t :: %{
          backtest: stage(),
          walk_forward: stage(),
          monte_carlo: stage(),
          holdout: stage(),
          live: map()
        }

  @doc "Results for each assignment id."
  @spec for_ids([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => t()}
  def for_ids(ids) do
    configs = latest_configs(ids)
    evaluations = configs |> Map.values() |> Enum.map(&elem(&1, 0)) |> evaluations()
    live = live(ids)

    Map.new(ids, fn id ->
      run =
        case configs[id] do
          {config_id, ran_at} -> {ran_at, Map.get(evaluations, config_id, %{})}
          nil -> nil
        end

      {id, run |> stages() |> Map.put(:live, Map.get(live, id, %{trades: 0}))}
    end)
  end

  @doc """
  Test runs of a recipe that isn't assigned anywhere yet, one per
  instrument it was tested on (the newest): `%{instrument, ran_at, stages}` with
  `stages` shaped as in `for_ids/1`. Matched by the recipe's rules: a run's
  strategy JSON minus instrument, timeframe and sizing, on the recipe's
  timeframe (the same rules on another timeframe are a different test).
  """
  @spec for_recipe(map(), String.t()) :: [map()]
  def for_recipe(definition, granularity) do
    configs =
      from(sc in StrategyConfig,
        where:
          sc.granularity == ^granularity and
            fragment(
              "(? - 'instrument' - 'granularity' - 'sizing') = ?",
              sc.parameters,
              type(^definition, :map)
            ),
        order_by: [asc: sc.instrument, desc: sc.inserted_at],
        distinct: sc.instrument,
        select: {sc.instrument, sc.id, sc.inserted_at}
      )
      |> Repo.all()

    evaluations = configs |> Enum.map(&elem(&1, 1)) |> evaluations()

    Enum.map(configs, fn {instrument, id, ran_at} ->
      %{
        instrument: instrument,
        ran_at: ran_at,
        stages: stages({ran_at, Map.get(evaluations, id, %{})})
      }
    end)
  end

  # The four pipeline stages of one run, `{ran_at, evaluations by stage}`,
  # or nil when the assignment has never been through the pipeline. A
  # stage with no row yet is waiting when the one before it passed (or it's
  # the backtest); runs from before the holdout stage existed have none.
  defp stages(nil) do
    Map.new(@stages, fn stage ->
      {@stage_keys[stage], not_run("Never run through the testing pipeline.")}
    end)
  end

  defp stages({ran_at, by_stage}),
    do: Map.new(@stages, &{@stage_keys[&1], stage(&1, ran_at, by_stage)})

  defp stage(stage, ran_at, by_stage) do
    case {by_stage[stage], by_stage[@previous[stage]]} do
      # A pass from before Oct 28 was judged on looser rules and recorded
      # no checks; it reads as that, not as meeting today's standard.
      {%{status: "passed", stats: stats} = e, _previous}
      when is_nil(stats) or not is_map_key(stats, "checks") ->
        %{
          status: :old_pass,
          stats: e.stats,
          at: e.evaluated_at,
          reason:
            "Passed the rules in use before Oct 28 and hasn't been re-run since. Re-test it to judge it by today's standard.",
          checks: []
        }

      {%{status: status} = e, _previous} ->
        %{
          status: Map.fetch!(@statuses, status),
          stats: e.stats,
          at: e.evaluated_at,
          reason: if(status == "failed", do: e.failure_reason),
          checks: checks(e.stats, e.failure_reason)
        }

      {nil, %{status: "failed"}} ->
        not_run("Skipped because the #{words(@previous[stage])} failed.")

      {nil, %{status: "passed"}} when stage == "holdout" ->
        if DateTime.compare(ran_at, @holdout_added) == :lt,
          do:
            not_run(
              "Not run. It's a one-time look at data kept aside; tests run since Oct 17 " <>
                "include it after Monte Carlo, and these ran before that."
            ),
          else: waiting()

      {nil, %{status: _passed_or_running}} ->
        waiting()

      {nil, nil} when stage == "backtest" ->
        waiting()

      {nil, nil} ->
        not_run("Not run.")
    end
  end

  defp waiting, do: %{status: :pending, stats: nil, at: nil, reason: nil, checks: []}
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

  # Newest pipeline run per assignment: assignment id => config id.
  defp latest_configs(ids) do
    from(sc in StrategyConfig,
      join: ls in LiveStrategy,
      on:
        ls.instrument == sc.instrument and ls.granularity == sc.granularity and
          fragment(
            "(? - 'instrument' - 'granularity' - 'sizing') = (? - 'instrument' - 'granularity' - 'sizing')",
            sc.parameters,
            ls.parameters
          ),
      where: ls.id in ^ids,
      order_by: [asc: ls.id, desc: sc.inserted_at],
      distinct: ls.id,
      select: {ls.id, {sc.id, sc.inserted_at}}
    )
    |> Repo.all()
    |> Map.new()
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
