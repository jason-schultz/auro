defmodule Opus.Pipeline.Stuck do
  @moduledoc """
  Whether anything is going to finish a pipeline stage that looks waiting
  or running, and the one way to pick a stopped run up again.

  A stage is **stuck** when it looks unfinished (no result yet, or a
  `running` evaluation row) and nothing is working on it:

    * no Oban job of that stage's worker for that config is `available`,
      `scheduled` (a snoozed job waiting for the tester is scheduled),
      `executing`, `retryable` or `suspended`; and
    * no `running` evaluation row for it was started within the stage's
      window (`@windows`).

  The windows: the tester writes the `running` row when a stage starts
  and touches it again only when it finishes, so the window has to outlast
  the longest real run. Opus gives up on the tester after the request
  timeout in `Opus.Auro.Client` (2 minutes for the backtest, walk-forward,
  Monte Carlo and holdout; 15 for the nearby-settings test, which re-runs
  the backtest at every nearby setting, the same for a basket); when it
  does, the job ends and the engine drops the request, so a `running` row
  older than that has nobody behind it. The windows are about seven and
  three times those timeouts: 15 minutes, and 45 for the nearby-settings
  test. A row inside its window counts as running even with no job, so a
  stage whose job was lost while the engine still finishes it isn't
  called stuck too early.

  Seen from the pages it's `Opus.Trading.StrategyResults` that decides
  (it calls `stuck?/5` for every unfinished stage); `resume/3` re-checks
  through it and enqueues the stage's worker, the same job the chain would
  have enqueued. Nothing here resumes on its own: the dashboard reports
  stuck runs (`list/0`) and a person decides, because the holdout is a
  one-time look.
  """

  import Ecto.Query

  alias Opus.Pipeline.{
    BacktestWorker,
    HoldoutWorker,
    MonteCarloWorker,
    ParameterStabilityWorker,
    StrategyConfig,
    StrategyEvaluation,
    WalkForwardWorker
  }

  alias Opus.Repo
  alias Opus.Trading.{Recipe, Strategies, StrategyResults}

  @workers %{
    "backtest" => BacktestWorker,
    "walk_forward" => WalkForwardWorker,
    "monte_carlo" => MonteCarloWorker,
    "parameter_stability" => ParameterStabilityWorker,
    "holdout" => HoldoutWorker
  }
  @stages Map.new(@workers, fn {stage, worker} -> {inspect(worker), stage} end)

  # Oban states with a job still going to run (or running).
  @live_states ~w(available scheduled executing retryable suspended)

  # Seconds a `running` row counts as running without a job (see the moduledoc).
  @windows %{
    "backtest" => 15 * 60,
    "walk_forward" => 15 * 60,
    "monte_carlo" => 15 * 60,
    "parameter_stability" => 45 * 60,
    "holdout" => 15 * 60
  }

  @typedoc "`{config_id, stage}` pairs with a live job."
  @type live :: MapSet.t({Ecto.UUID.t(), String.t()})

  @doc "The stages of these configs that have a live Oban job, as `{config_id, stage}`."
  @spec live_jobs([Ecto.UUID.t()]) :: live()
  def live_jobs([]), do: MapSet.new()

  def live_jobs(config_ids) do
    from(j in Oban.Job,
      where:
        j.worker in ^Map.keys(@stages) and j.state in @live_states and
          fragment("?->>'config_id'", j.args) in ^config_ids,
      select: {fragment("?->>'config_id'", j.args), j.worker}
    )
    |> Repo.all()
    |> MapSet.new(fn {config_id, worker} -> {config_id, @stages[worker]} end)
  end

  @doc """
  Whether a stage that looks unfinished (`evaluation` is its row, or nil)
  has nothing working on it: no live job in `live` (`live_jobs/1`) and no
  `running` row started within its window.
  """
  @spec stuck?(Ecto.UUID.t(), String.t(), StrategyEvaluation.t() | nil, live(), DateTime.t()) ::
          boolean()
  def stuck?(config_id, stage, evaluation, live, now) do
    not MapSet.member?(live, {config_id, stage}) and not started_lately?(evaluation, stage, now)
  end

  defp started_lately?(%{status: "running", updated_at: %DateTime{} = at}, stage, now),
    do: DateTime.diff(now, at) < Map.fetch!(@windows, stage)

  defp started_lately?(_evaluation, _stage, _now), do: false

  @doc """
  Pick a stuck run up again at `stage`: enqueue that stage's worker for
  the config, the job the chain would have enqueued. Refused unless the
  stage is stuck as the pages show it (so never a stage with a result, nor
  one whose stage before it hasn't passed), never for an archived run, and
  for the holdout only with `holdout: :confirmed`: running it takes the
  one-time look at the data kept aside.
  """
  @spec resume(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()}
          | {:error, :not_found | :not_stuck | :archived | :holdout_needs_confirm | term()}
  def resume(config_id, stage, opts \\ []) do
    with {:ok, worker} <- Map.fetch(@workers, stage) |> ok_or(:not_stuck),
         {%StrategyConfig{} = config, archived} <- get(config_id) || {:error, :not_found},
         :ok <- if(archived, do: {:error, :archived}, else: :ok),
         :ok <- confirmed(stage, opts),
         %{status: :stuck} <- stage_now(config, stage) || {:error, :not_stuck} do
      case Oban.insert(worker.new(%{config_id: config.id})) do
        # The worker's uniqueness found a job already waiting: not stuck after all.
        {:ok, %Oban.Job{conflict?: true}} -> {:error, :not_stuck}
        {:ok, job} -> {:ok, job}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
      _stage -> {:error, :not_stuck}
    end
  end

  defp ok_or({:ok, value}, _reason), do: {:ok, value}
  defp ok_or(:error, reason), do: {:error, reason}

  # The config and whether it's archived (`archived_at` isn't loaded by default).
  defp get(config_id) do
    case Ecto.UUID.cast(config_id) do
      {:ok, id} ->
        Repo.one(
          from(c in StrategyConfig, where: c.id == ^id, select: {c, not is_nil(c.archived_at)})
        )

      :error ->
        nil
    end
  end

  defp confirmed("holdout", opts) do
    if Keyword.get(opts, :holdout) == :confirmed, do: :ok, else: {:error, :holdout_needs_confirm}
  end

  defp confirmed(_stage, _opts), do: :ok

  defp stage_now(config, stage) do
    StrategyResults.for_configs([{config.id, config.inserted_at}])
    |> Map.fetch!(config.id)
    |> Map.fetch!(String.to_existing_atom(stage))
  end

  @doc """
  Every stuck run that isn't archived, oldest first: `%{config_id,
  instrument, granularity, name, basket, stage, started, recipe_id}`
  (`stage` an atom; `started` whether the stage began, i.e. it has a
  `running` row; `recipe_id` the strategy whose rules it tested, nil if
  none has them now). For the dashboard; it only reports.
  """
  @spec list() :: [map()]
  def list do
    # Runs not finished: nothing failed and the holdout hasn't passed.
    configs =
      from(c in StrategyConfig,
        as: :config,
        where:
          is_nil(c.archived_at) and
            not exists(
              from(e in StrategyEvaluation,
                where:
                  e.strategy_config_id == parent_as(:config).id and
                    (e.status == "failed" or (e.stage == "holdout" and e.status == "passed"))
              )
            ),
        order_by: [asc: c.inserted_at]
      )
      |> Repo.all()

    stages = StrategyResults.for_configs(Enum.map(configs, &{&1.id, &1.inserted_at}))
    recipes = recipes(configs)

    for config <- configs,
        {stage, %{status: :stuck} = result} <- stages[config.id] do
      %{
        config_id: config.id,
        instrument: config.instrument,
        granularity: config.granularity,
        name: config.parameters["strategy_name"],
        basket: Map.has_key?(config.parameters, "basket"),
        stage: stage,
        started: result.started,
        recipe_id: recipes[rules(config)]
      }
    end
  end

  # Strategy ids by `{settings, timeframe}`, matched the way the strategy
  # pages match their runs (`StrategyResults.for_recipe/2`, `for_baskets/2`).
  defp recipes([]), do: %{}

  defp recipes(configs) do
    granularities = configs |> Enum.map(& &1.granularity) |> Enum.uniq()

    from(r in Recipe,
      where: r.granularity in ^granularities,
      select: {r.definition, r.granularity, r.id}
    )
    |> Repo.all()
    |> Map.new(fn {definition, granularity, id} ->
      {{Strategies.trade_settings(definition), granularity}, id}
    end)
  end

  defp rules(config), do: {Strategies.trade_settings(config.parameters), config.granularity}
end
