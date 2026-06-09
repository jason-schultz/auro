defmodule Opus.Pipeline.GenerationSpawnerWorker do
  @moduledoc """
  Coordinates the evolutionary strategy optimization loop.

  Triggered whenever a config in an evo lineage reaches a terminal state
  (passed all pipeline stages, or failed at any stage). Oban's unique
  constraint ensures only one spawner job runs per (lineage_id, evo_generation)
  regardless of how many siblings trigger it.

  Uses {:snooze, 30} to re-check every 30 seconds until all children in the
  current generation are terminal, then:
    - Spawns the next generation from the highest-scoring child, or
    - Promotes the winner to live_strategies if max generations reached, or
    - Terminates the lineage if no child scored above zero.

  Scoring function (all components from pipeline OOS metrics):
    score = oos_sharpe × clamp(sharpe_retention, 0, 1.5)
              × log(oos_num_trades + 1) × profitable_pct_mc

  Mutation uses Gaussian noise with linearly-decaying sigma:
    sigma = 20% of parameter value at generation 1, shrinking to 4% at gen 5.
  """

  use Oban.Worker,
    queue: :pipeline,
    unique: [period: 3_600, keys: [:lineage_id, :evo_generation]],
    max_attempts: 1

  require Logger
  import Ecto.Query

  alias Opus.Pipeline.{Coordinator, StrategyConfig, StrategyEvaluation}
  alias Opus.Repo

  @max_generations 5
  @children_per_gen 10
  @base_sigma 0.20

  # ---------------------------------------------------------------------------
  # Oban callback
  # ---------------------------------------------------------------------------

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"lineage_id" => lineage_id, "evo_generation" => evo_generation}
      }) do
    configs = list_generation_configs(lineage_id, evo_generation)
    total = length(configs)
    terminal_count = Enum.count(configs, &terminal?/1)

    cond do
      total == 0 ->
        Logger.warning(
          "[EvoEngine] lineage=#{lineage_id} gen=#{evo_generation}: no configs found — terminating lineage"
        )

        :ok

      terminal_count < total ->
        Logger.info(
          "[EvoEngine] lineage=#{lineage_id} gen=#{evo_generation}: " <>
            "#{terminal_count}/#{total} terminal — snoozing"
        )

        {:snooze, 30}

      true ->
        children = build_children_with_stats(configs)

        # Exploratory seed at gen 0 is a non-backtested placeholder (score force-set
        # at creation, no eval rows). Its sole role is to spawn gen 1 — fitness/
        # termination logic can't apply because there are no stats. Spawn directly.
        # (Safe: gen>=1 children always have eval rows by the time they're terminal,
        # and non-exploratory seeds are backtested, so only this case has zero stats.)
        if Enum.all?(children, &(is_nil(&1.bt_stats) and is_nil(&1.wf_stats))) do
          seed = Enum.max_by(configs, &(&1.score || 0.0))

          if evo_generation < max_generations_for(seed.strategy_type) do
            Logger.info(
              "[EvoEngine] lineage=#{lineage_id} gen=#{evo_generation}: " <>
                "un-evaluated exploratory seed — spawning #{@children_per_gen} children for gen #{evo_generation + 1}"
            )

            spawn_next_generation(seed, lineage_id, evo_generation + 1)
          else
            Logger.info(
              "[EvoEngine] lineage=#{lineage_id}: un-evaluated seed at max_gen — terminating"
            )
          end

          :ok
        else
          {parent, best_fitness} = select_parent(children)
          max_gen = max_generations_for(parent.strategy_type)

          cond do
            best_fitness <= 0.0 ->
              Logger.info(
                "[EvoEngine] lineage=#{lineage_id} gen=#{evo_generation}: " <>
                  "no viable children (best_fitness=#{Float.round(best_fitness, 4)}) — terminating lineage"
              )

              :ok

            evo_generation >= max_gen ->
              validated = Enum.filter(configs, fn c -> (c.score || 0.0) > 0.0 end)

              case validated do
                [] ->
                  Logger.info(
                    "[EvoEngine] lineage=#{lineage_id} gen=#{evo_generation}: " <>
                      "reached max generations (max=#{max_gen}) with no validated winner — terminating lineage"
                  )

                  :ok

                winners ->
                  winner = Enum.max_by(winners, &(&1.score || 0.0))
                  winner_score = winner.score || 0.0

                  Logger.info(
                    "[EvoEngine] lineage=#{lineage_id} max generations reached " <>
                      "(gen=#{evo_generation}, max=#{max_gen}) — " <>
                      "promoting validated winner #{winner.id} (score=#{Float.round(winner_score, 4)})"
                  )

                  Coordinator.promote_to_live(to_string(winner.id))
                  :ok
              end

            true ->
              next_gen = evo_generation + 1

              Logger.info(
                "[EvoEngine] lineage=#{lineage_id} gen=#{evo_generation} parent=#{parent.id} " <>
                  "(fitness=#{Float.round(best_fitness, 4)}) — spawning #{@children_per_gen} children for gen #{next_gen}"
              )

              spawn_next_generation(parent, lineage_id, next_gen)
              :ok
          end
        end
    end
  end

  # Per-strategy-class max generations. TF v1 is strict textbook (50/200, no
  # mutation) per decision-canonical-strategy-shape Option A, so the lineage
  # promotes at gen 0 — no spawning. Other classes (MR) keep the default evo
  # depth.
  defp max_generations_for("trend_following"), do: 0
  defp max_generations_for("donchian"), do: 0
  defp max_generations_for("rsi2_dipbuy"), do: 0
  defp max_generations_for(_), do: @max_generations

  # ---------------------------------------------------------------------------
  # Terminal check
  # ---------------------------------------------------------------------------

  defp list_generation_configs(lineage_id, evo_generation) do
    from(c in StrategyConfig,
      where: c.lineage_id == ^lineage_id and c.evo_generation == ^evo_generation
    )
    |> Repo.all()
  end

  # A config is terminal if it has a computed score (MC passed)
  # OR has any failed evaluation at any stage.
  defp terminal?(config) do
    not is_nil(config.score) or has_failed_evaluation?(config.id)
  end

  defp has_failed_evaluation?(config_id) do
    Repo.exists?(
      from e in StrategyEvaluation,
        where: e.strategy_config_id == ^config_id and e.status == "failed"
    )
  end

  defp build_children_with_stats(configs) do
    config_ids = Enum.map(configs, & &1.id)

    stats_rows =
      Repo.all(
        from e in StrategyEvaluation,
          where:
            e.strategy_config_id in ^config_ids and
              e.stage in ["backtest", "walk_forward"],
          select: {e.strategy_config_id, e.stage, e.stats}
      )

    stats_by_id =
      Enum.reduce(stats_rows, %{}, fn {config_id, stage, stats}, acc ->
        child_stats = Map.get(acc, config_id, %{bt_stats: nil, wf_stats: nil})

        updated =
          case stage do
            "backtest" -> %{child_stats | bt_stats: stats}
            "walk_forward" -> %{child_stats | wf_stats: stats}
            _ -> child_stats
          end

        Map.put(acc, config_id, updated)
      end)

    Enum.map(configs, fn config ->
      child_stats = Map.get(stats_by_id, config.id, %{bt_stats: nil, wf_stats: nil})

      %{
        config: config,
        bt_stats: child_stats.bt_stats,
        wf_stats: child_stats.wf_stats
      }
    end)
  end

  @doc false
  def breeding_fitness_oos(wf_stats) when is_map(wf_stats) do
    oos_sharpe = metric(wf_stats, "oos_sharpe")
    retention = metric(wf_stats, "sharpe_retention")
    oos_trades = metric(wf_stats, "oos_num_trades")

    retention_capped = max(0.0, min(retention, 1.5))
    oos_sharpe * retention_capped * :math.log(oos_trades + 1.0)
  end

  def breeding_fitness_oos(_), do: 0.0

  @doc false
  def breeding_fitness_insample(bt_stats) when is_map(bt_stats) do
    expectancy = metric(bt_stats, "expectancy")

    if expectancy > 0.0 do
      sharpe = metric(bt_stats, "sharpe")
      num_trades = metric(bt_stats, "num_trades")
      sharpe * :math.log(num_trades + 1.0)
    else
      0.0
    end
  end

  def breeding_fitness_insample(_), do: 0.0

  @doc false
  def select_parent(children_with_stats) do
    wf_reachers = Enum.filter(children_with_stats, fn child -> not is_nil(child.wf_stats) end)

    candidates = if wf_reachers == [], do: children_with_stats, else: wf_reachers

    Enum.reduce(candidates, {nil, -1.0e308}, fn child, {best_config, best_fitness} ->
      fitness =
        if wf_reachers == [] do
          breeding_fitness_insample(child.bt_stats)
        else
          breeding_fitness_oos(child.wf_stats)
        end

      if fitness > best_fitness do
        {child.config, fitness}
      else
        {best_config, best_fitness}
      end
    end)
  end

  defp metric(stats, key) when is_map(stats) do
    atom_key =
      case key do
        "oos_sharpe" -> :oos_sharpe
        "sharpe_retention" -> :sharpe_retention
        "oos_num_trades" -> :oos_num_trades
        "sharpe" -> :sharpe
        "num_trades" -> :num_trades
        "expectancy" -> :expectancy
        _ -> nil
      end

    value =
      Map.get(stats, key) ||
        if(atom_key, do: Map.get(stats, atom_key), else: nil) ||
        0.0

    cond do
      is_integer(value) -> value * 1.0
      is_float(value) -> value
      true -> 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # Spawn next generation
  # ---------------------------------------------------------------------------

  defp spawn_next_generation(parent, lineage_id, next_gen) do
    case list_generation_configs(lineage_id, next_gen) do
      [] ->
        1..@children_per_gen
        |> Enum.each(fn _ ->
          child_params =
            mutate_params(
              parent.strategy_type,
              parent.parameters,
              parent.granularity,
              next_gen
            )

          attrs = %{
            instrument: parent.instrument,
            granularity: parent.granularity,
            strategy_type: parent.strategy_type,
            source: "evolution",
            parent_config_id: to_string(parent.id),
            depth: 0,
            parameters: child_params,
            evo_generation: next_gen,
            lineage_id: lineage_id
          }

          case Coordinator.submit_evo_child(attrs) do
            {:ok, child} ->
              Logger.debug("[EvoEngine] Spawned gen #{next_gen} child #{child.id}")

            {:error, reason} ->
              Logger.error(
                "[EvoEngine] Failed to spawn gen #{next_gen} child: #{inspect(reason)}"
              )
          end
        end)

      existing ->
        Logger.warning(
          "[EvoEngine] gen #{next_gen} for lineage #{lineage_id} already has " <>
            "#{length(existing)} children — skipping duplicate spawn"
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Mutation — Gaussian with linearly-decaying sigma
  # ---------------------------------------------------------------------------

  # MR v1 (Investopedia baseline) in the composite strategy shape — see
  # decision-canonical-strategy-shape. Mutates only the inner MeanReversion
  # component's params; leaves the rest of the strategy structure unchanged.
  defp mutate_params(
         "mean_reversion",
         %{"components" => %{"mr" => %{"params" => mr_params}}} = composite,
         _granularity,
         generation
       ) do
    sf = sigma_fraction(generation)

    mutated_mr = %{
      "ma_period" => mutate_integer(mr_params["ma_period"], sf, 5, 200),
      "rsi_period" => mutate_integer(mr_params["rsi_period"], sf, 5, 30),
      "entry_z_threshold" => mutate_float(mr_params["entry_z_threshold"], sf, 1.0, 3.0),
      "rsi_oversold" => mutate_float(mr_params["rsi_oversold"], sf, 15.0, 40.0),
      "rsi_overbought" => mutate_float(mr_params["rsi_overbought"], sf, 60.0, 85.0),
      "stop_z_threshold" => mutate_float(mr_params["stop_z_threshold"], sf, 2.0, 6.0)
    }

    put_in(composite, ["components", "mr", "params"], mutated_mr)
  end

  # Legacy flat-shape MR — kept as a fallback for any lingering pre-composite
  # MR lineages still in the DB. New MR seeds use the composite shape above.
  defp mutate_params("mean_reversion", params, _granularity, generation) do
    sf = sigma_fraction(generation)

    %{
      "ma_period" => mutate_integer(params["ma_period"], sf, 5, 200),
      "rsi_period" => mutate_integer(params["rsi_period"], sf, 5, 30),
      "entry_z_threshold" => mutate_float(params["entry_z_threshold"], sf, 1.0, 3.0),
      "rsi_oversold" => mutate_float(params["rsi_oversold"], sf, 15.0, 40.0),
      "rsi_overbought" => mutate_float(params["rsi_overbought"], sf, 60.0, 85.0),
      "stop_z_threshold" => mutate_float(params["stop_z_threshold"], sf, 2.0, 6.0)
    }
  end

  defp mutate_params("trend_following", _params, _granularity, _generation) do
    # TF v1 is strict textbook (50/200, no mutation). max_generations_for/1
    # returns 0 for "trend_following" so the spawner promotes at gen 0 and
    # never calls into this branch. Raise loudly if it ever does — that
    # indicates a misconfiguration upstream.
    raise "trend_following is non-evolving (textbook v1); mutate_params should never be called"
  end

  defp mutate_params("donchian", _params, _granularity, _generation) do
    raise "donchian is non-evolving (textbook v1); mutate_params should never be called"
  end

  defp mutate_params("rsi2_dipbuy", _params, _granularity, _generation) do
    raise "rsi2_dipbuy is non-evolving baseline; mutate_params should never be called"
  end

  # sigma decays linearly: 20% at gen 1 → 4% at gen 5
  defp sigma_fraction(generation) do
    @base_sigma * (1.0 - (generation - 1) / @max_generations)
  end

  defp mutate_float(value, sigma_f, min_val, max_val) do
    sigma = abs(value) * sigma_f
    noise = :rand.normal() * sigma
    clamp(value + noise, min_val, max_val)
  end

  defp mutate_integer(value, sigma_f, min_val, max_val) do
    mutate_float(value * 1.0, sigma_f, min_val * 1.0, max_val * 1.0) |> round()
  end

  defp clamp(value, min_val, max_val), do: max(min_val, min(max_val, value))

  # ---------------------------------------------------------------------------
  # Public: score computation (called by MonteCarloWorker)
  # ---------------------------------------------------------------------------

  @doc """
  Computes the composite pipeline score from walk_forward and monte_carlo
  evaluation stats, saves it to strategy_configs.score, and returns the score.

  Score = oos_sharpe × clamp(sharpe_retention, 0, 1.5)
            × log(oos_num_trades + 1) × profitable_pct_mc

  Returns 0.0 if oos_sharpe <= 0 or any required stats are missing.

  CHECK BEFORE TUNING MORE CODE: this function's weights are the primary
  driver of which configs get promoted. The log() term may under-penalize
  low OOS trade counts on H4 timeframes — if you're seeing good scores on
  configs with < 8 OOS trades, tighten the trade-count penalty here.
  """
  @spec compute_and_save_score(binary()) :: float()
  def compute_and_save_score(config_id) do
    wf_stats =
      Repo.one(
        from e in StrategyEvaluation,
          where:
            e.strategy_config_id == ^config_id and
              e.stage == "walk_forward" and
              e.status == "passed",
          select: e.stats
      )

    mc_stats =
      Repo.one(
        from e in StrategyEvaluation,
          where:
            e.strategy_config_id == ^config_id and
              e.stage == "monte_carlo" and
              e.status == "passed",
          select: e.stats
      )

    score = compute_score(wf_stats, mc_stats)

    from(c in StrategyConfig, where: c.id == ^config_id)
    |> Repo.update_all(set: [score: score])

    Logger.info(
      "[EvoEngine] Scored config #{config_id}: #{Float.round(score, 4)} " <>
        "(oos_sharpe=#{get_in(wf_stats || %{}, ["oos_sharpe"])}, " <>
        "retention=#{get_in(wf_stats || %{}, ["sharpe_retention"])}, " <>
        "oos_trades=#{get_in(wf_stats || %{}, ["oos_num_trades"])}, " <>
        "profitable_pct=#{get_in(mc_stats || %{}, ["profitable_pct"])})"
    )

    score
  end

  defp compute_score(nil, _), do: 0.0
  defp compute_score(_, nil), do: 0.0

  defp compute_score(wf_stats, mc_stats) do
    oos_sharpe = Map.get(wf_stats, "oos_sharpe") || 0.0
    retention = Map.get(wf_stats, "sharpe_retention") || 0.0
    oos_trades = Map.get(wf_stats, "oos_num_trades") || 0
    profitable_pct = Map.get(mc_stats, "profitable_pct") || 0.0

    if oos_sharpe <= 0.0 do
      0.0
    else
      retention_capped = max(0.0, min(retention, 1.5))
      oos_sharpe * retention_capped * :math.log(oos_trades + 1) * profitable_pct
    end
  end
end
