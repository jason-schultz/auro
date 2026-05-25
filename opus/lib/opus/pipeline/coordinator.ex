defmodule Opus.Pipeline.Coordinator do
  @moduledoc """
  Public API for the automated strategy discovery pipeline.

  Flow per config:
    submit_config/1 (depth=0) or submit_iteration/2 (depth=N)
      → inserts strategy_configs row
      → enqueues BacktestWorker
      → on pass  → WalkForwardWorker → MonteCarloWorker (log for manual review)
      → on fail  → OllamaIterationWorker → submit_iteration/2 (depth+1, max 10)
  """

  require Logger
  import Ecto.Query

  alias Ecto.Multi

  alias Opus.Pipeline.{
    BacktestWorker,
    GenerationSpawnerWorker,
    StrategyConfig,
    StrategyEvaluation
  }

  alias Opus.Repo

  @type pipeline_status_row :: %{
          config_id: Ecto.UUID.t(),
          instrument: String.t(),
          granularity: String.t(),
          strategy_type: String.t(),
          source: String.t() | nil,
          depth: non_neg_integer(),
          parent_config_id: Ecto.UUID.t() | nil,
          stage: String.t() | nil,
          status: String.t() | nil,
          stats: map() | nil,
          failure_reason: String.t() | nil,
          evaluated_at: DateTime.t() | nil
        }

  @doc """
  Insert a child config derived from a failing config with Ollama-revised parameters,
  then kick off its backtest stage at the given depth.

  Returns `{:ok, config}` or `{:error, reason}`.
  """
  @spec submit_iteration(
          StrategyConfig.t(),
          %{
            required(:parameters) => map(),
            required(:depth) => non_neg_integer(),
            optional(:generation_prompt) => String.t()
          }
        ) :: {:ok, StrategyConfig.t()} | {:error, term()}
  def submit_iteration(parent_config, %{parameters: revised_params, depth: depth} = opts) do
    if params_seen_in_lineage?(parent_config.id, revised_params) do
      Logger.info(
        "[Pipeline] Params already seen in lineage for #{parent_config.instrument} " <>
          "#{parent_config.strategy_type} (depth #{depth}), stopping chain"
      )

      {:error, :unchanged_parameters}
    else
      do_submit_iteration(parent_config, revised_params, depth, opts)
    end
  end

  defp do_submit_iteration(parent_config, revised_params, depth, opts) do
    attrs = %{
      instrument: parent_config.instrument,
      granularity: parent_config.granularity,
      strategy_type: parent_config.strategy_type,
      source: "ollama",
      parent_config_id: to_string(parent_config.id),
      parameters: revised_params,
      depth: depth,
      generation_prompt: Map.get(opts, :generation_prompt)
    }

    changeset = StrategyConfig.changeset(%StrategyConfig{}, attrs)

    multi =
      Multi.new()
      |> Multi.insert(:config, changeset)
      |> Multi.insert(:backtest_job, fn %{config: config} ->
        BacktestWorker.new(%{config_id: to_string(config.id), depth: depth})
      end)

    case Repo.transaction(multi) do
      {:ok, %{config: config}} ->
        Logger.info(
          "[Pipeline] Submitted iteration config #{config.id} at depth=#{depth} " <>
            "(parent: #{parent_config.id})"
        )

        {:ok, config}

      {:error, :config, changeset, _changes_so_far} ->
        {:error, changeset}

      {:error, :backtest_job, reason, _changes_so_far} ->
        Logger.error(
          "[Pipeline] Failed to enqueue backtest for iteration config: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Walk the full ancestor chain and return true if revised_params appeared at any depth.
  defp params_seen_in_lineage?(config_id, revised_params) do
    normalized = normalize_params(revised_params)

    case lineage_params_via_cte(config_id) do
      {:ok, params_list} ->
        Enum.any?(params_list, &(normalize_params(&1) == normalized))

      {:error, reason} ->
        Logger.warning(
          "[Pipeline] lineage CTE failed for #{config_id}, falling back to iterative traversal: #{inspect(reason)}"
        )

        config_id
        |> lineage_stream()
        |> Enum.any?(fn {_id, params} -> normalize_params(params) == normalized end)
    end
  end

  defp lineage_params_via_cte(config_id) do
    seed_query =
      from(c in StrategyConfig,
        where: c.id == ^config_id,
        select: %{id: c.id, parent_config_id: c.parent_config_id, parameters: c.parameters}
      )

    step_query =
      from(c in StrategyConfig,
        join: l in "lineage",
        on: c.id == l.parent_config_id,
        select: %{id: c.id, parent_config_id: c.parent_config_id, parameters: c.parameters}
      )

    lineage_query = union_all(seed_query, ^step_query)

    query =
      from(l in "lineage", select: l.parameters)
      |> recursive_ctes(true)
      |> with_cte("lineage", as: ^lineage_query)

    case Repo.all(query) do
      params_list when is_list(params_list) -> {:ok, Enum.map(params_list, &(&1 || %{}))}
      _ -> {:error, :unexpected_lineage_result}
    end
  rescue
    error ->
      {:error, error}
  end

  defp lineage_stream(config_id) do
    Stream.unfold(config_id, fn
      nil ->
        nil

      id ->
        case fetch_lineage_node(id) do
          nil ->
            nil

          %{id: node_id, parent_config_id: parent, parameters: params} ->
            {{node_id, params}, parent}
        end
    end)
  end

  defp fetch_lineage_node(config_id) do
    from(c in StrategyConfig,
      where: c.id == ^config_id,
      select: %{id: c.id, parent_config_id: c.parent_config_id, parameters: c.parameters}
    )
    |> Repo.one()
  end

  defp normalize_params(params) when is_map(params) do
    Map.new(params, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  @doc """
  Start an evolutionary optimization lineage from a seed config.

  Creates a generation-0 seed config, sets its lineage_id to its own ID,
  and kicks off the pipeline. A GenerationSpawnerWorker is also inserted
  immediately — it will snooze until the seed is terminal, then decide
  whether to spawn generation 1.

  `attrs` must include: instrument, granularity, strategy_type, parameters.

  Example from iex:
      Opus.Pipeline.Coordinator.submit_evo_seed(%{
        instrument: "EUR_USD",
        granularity: "H1",
        strategy_type: "mean_reversion",
        parameters: %{"ma_period" => 20, "entry_threshold" => -0.003,
                      "exit_threshold" => 0.002, "stop_loss" => -0.005,
                      "regime_filter" => true}
      })
  """
  @spec submit_evo_seed(map()) :: {:ok, StrategyConfig.t()} | {:error, term()}
  def submit_evo_seed(attrs) do
    changeset =
      StrategyConfig.changeset(
        %StrategyConfig{},
        Map.merge(attrs, %{source: "manual", depth: 0, evo_generation: 0})
      )

    multi =
      Multi.new()
      |> Multi.insert(:config, changeset)
      |> Multi.update(:set_lineage, fn %{config: config} ->
        StrategyConfig.changeset(config, %{lineage_id: to_string(config.id)})
      end)
      |> Multi.insert(:backtest_job, fn %{config: config} ->
        BacktestWorker.new(%{
          config_id: to_string(config.id),
          depth: 0,
          lineage_id: to_string(config.id),
          evo_generation: 0
        })
      end)
      |> Multi.insert(:spawner_job, fn %{config: config} ->
        GenerationSpawnerWorker.new(%{
          lineage_id: to_string(config.id),
          evo_generation: 0
        })
      end)

    case Repo.transaction(multi) do
      {:ok, %{config: config}} ->
        Logger.info(
          "[Pipeline] Submitted evo seed #{config.id}: #{config.strategy_type} " <>
            "#{config.instrument} #{config.granularity} (lineage=#{config.id})"
        )

        {:ok, config}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Start an evolutionary lineage in exploratory mode.

  Unlike submit_evo_seed/1, this does NOT run the seed through the pipeline.
  Instead, it immediately spawns @children_per_gen generation-1 children by
  mutating the seed parameters. The pipeline runs on the children, not the seed.
  This allows the evo engine to find viable regions even when the exact seed
  parameters would fail the pipeline.

  Use this when you have a rough starting point but aren't sure it passes
  backtest thresholds. Use submit_evo_seed/1 when you have a known-good
  config you want to refine.
  """
  @spec submit_evo_seed_exploratory(map()) :: {:ok, StrategyConfig.t()} | {:error, term()}
  def submit_evo_seed_exploratory(attrs) do
    changeset =
      StrategyConfig.changeset(
        %StrategyConfig{},
        Map.merge(attrs, %{source: "manual", depth: 0, evo_generation: 0})
      )

    multi =
      Multi.new()
      |> Multi.insert(:config, changeset)
      |> Multi.update(:set_lineage, fn %{config: config} ->
        StrategyConfig.changeset(config, %{lineage_id: to_string(config.id), score: 1.0})
      end)
      |> Multi.insert(:spawner_job, fn %{config: config} ->
        # score: 1.0 means the seed is immediately "terminal and viable",
        # so the spawner will proceed to spawn generation 1 children.
        GenerationSpawnerWorker.new(%{
          lineage_id: to_string(config.id),
          evo_generation: 0
        })
      end)

    case Repo.transaction(multi) do
      {:ok, %{config: config}} ->
        Logger.info(
          "[Pipeline] Submitted exploratory evo seed #{config.id}: #{config.strategy_type} " <>
            "#{config.instrument} #{config.granularity} (lineage=#{config.id}, spawning gen-1 immediately)"
        )

        {:ok, config}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Insert a child config spawned by GenerationSpawnerWorker and kick off its pipeline.

  `attrs` must include all StrategyConfig fields plus evo_generation and lineage_id.
  """
  @spec submit_evo_child(map()) :: {:ok, StrategyConfig.t()} | {:error, term()}
  def submit_evo_child(attrs) do
    changeset = StrategyConfig.changeset(%StrategyConfig{}, attrs)
    lineage_id = Map.get(attrs, :lineage_id) || Map.get(attrs, "lineage_id")
    evo_generation = Map.get(attrs, :evo_generation) || Map.get(attrs, "evo_generation")

    multi =
      Multi.new()
      |> Multi.insert(:config, changeset)
      |> Multi.insert(:backtest_job, fn %{config: config} ->
        BacktestWorker.new(%{
          config_id: to_string(config.id),
          depth: 0,
          lineage_id: lineage_id,
          evo_generation: evo_generation
        })
      end)

    case Repo.transaction(multi) do
      {:ok, %{config: config}} -> {:ok, config}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Insert a new strategy config and kick off the backtest stage.

  `attrs` must include: instrument, granularity, strategy_type, parameters.
  Optional: source (defaults to "ollama"), parent_config_id.

  Returns `{:ok, config}` or `{:error, reason}`.
  """
  @spec submit_config(map()) :: {:ok, StrategyConfig.t()} | {:error, term()}
  def submit_config(attrs) do
    changeset = StrategyConfig.changeset(%StrategyConfig{}, Map.merge(attrs, %{depth: 0}))

    multi =
      Multi.new()
      |> Multi.insert(:config, changeset)
      |> Multi.insert(:backtest_job, fn %{config: config} ->
        BacktestWorker.new(%{config_id: to_string(config.id), depth: 0})
      end)

    case Repo.transaction(multi) do
      {:ok, %{config: config}} ->
        Logger.info(
          "[Pipeline] Submitted config #{config.id}: #{config.strategy_type} #{config.instrument} #{config.granularity}"
        )

        {:ok, config}

      {:error, :config, changeset, _changes_so_far} ->
        {:error, changeset}

      {:error, :backtest_job, reason, _changes_so_far} ->
        Logger.error(
          "[Pipeline] Failed to enqueue backtest for submitted config: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Promote a passed pipeline config to `live_strategies` (disabled, pending user enablement).

  Idempotent: if the (instrument, strategy_type, parameters) combination already exists in
  live_strategies, the insert is silently skipped and {:ok, :already_promoted} is returned.
  """
  @spec promote_to_live(String.t(), String.t()) ::
          {:ok, :promoted | :already_promoted} | {:error, :not_found}
  def promote_to_live(config_id, max_position_size \\ "1000") do
    case Repo.get(StrategyConfig, config_id) do
      nil ->
        {:error, :not_found}

      config ->
        now = DateTime.utc_now()

        {inserted, _rows} =
          Repo.insert_all(
            "live_strategies",
            [
              %{
                strategy_type: config.strategy_type,
                instrument: config.instrument,
                granularity: config.granularity,
                parameters: config.parameters,
                enabled: false,
                max_position_size: max_position_size,
                created_at: now,
                updated_at: now
              }
            ],
            on_conflict: :nothing,
            conflict_target: [:instrument, :strategy_type, :parameters]
          )

        if inserted == 1 do
          Logger.info(
            "[Pipeline] Promoted config #{config_id} to live_strategies (disabled) — " <>
              "#{config.strategy_type} #{config.instrument} #{config.granularity}"
          )

          {:ok, :promoted}
        else
          Logger.info(
            "[Pipeline] Config #{config_id} already in live_strategies, skipping promotion"
          )

          {:ok, :already_promoted}
        end
    end
  end

  @doc """
  List all configs and their current evaluation status across all stages.
  Returns a list of maps with config + evaluation rows joined.
  """
  @spec list_pipeline_status() :: [pipeline_status_row()]
  def list_pipeline_status do
    import Ecto.Query

    query =
      from(c in StrategyConfig,
        left_join: e in StrategyEvaluation,
        on: e.strategy_config_id == c.id,
        order_by: [desc: c.inserted_at, asc: e.stage],
        select: %{
          config_id: c.id,
          instrument: c.instrument,
          granularity: c.granularity,
          strategy_type: c.strategy_type,
          parameters: c.parameters,
          source: c.source,
          depth: c.depth,
          parent_config_id: c.parent_config_id,
          evo_generation: c.evo_generation,
          lineage_id: c.lineage_id,
          score: c.score,
          inserted_at: c.inserted_at,
          stage: e.stage,
          status: e.status,
          stats: e.stats,
          failure_reason: e.failure_reason,
          evaluated_at: e.evaluated_at
        }
      )

    Repo.all(query)
  end
end
