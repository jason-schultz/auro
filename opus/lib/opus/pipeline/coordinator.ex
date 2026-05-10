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

  alias Ecto.Multi
  alias Opus.Pipeline.{BacktestWorker, StrategyConfig, StrategyEvaluation}
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
    walk_lineage(config_id, normalized)
  end

  defp walk_lineage(nil, _normalized), do: false

  defp walk_lineage(config_id, normalized) do
    case Repo.get(StrategyConfig, config_id) do
      nil ->
        false

      config ->
        if normalize_params(config.parameters) == normalized do
          true
        else
          walk_lineage(config.parent_config_id, normalized)
        end
    end
  end

  defp normalize_params(params) when is_map(params) do
    Map.new(params, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
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
        id_bin = Ecto.UUID.dump!(Ecto.UUID.generate())
        now = DateTime.utc_now()

        result =
          Repo.query!(
            """
            INSERT INTO live_strategies
              (id, strategy_type, instrument, granularity, parameters, enabled, max_position_size, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, false, $6, $7, $7)
            ON CONFLICT (instrument, strategy_type, parameters) DO NOTHING
            """,
            [id_bin, config.strategy_type, config.instrument, config.granularity, config.parameters, max_position_size, now]
          )

        if result.num_rows == 1 do
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
