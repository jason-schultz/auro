defmodule Opus.Pipeline.Coordinator do
  @moduledoc """
  Public API for the strategy validation pipeline.

  The pipeline is a judge for hand-specified configs, not a search:

      submit_config/1
        → inserts a strategy_configs row
        → BacktestWorker → WalkForwardWorker → MonteCarloWorker → HoldoutWorker
        → any failing stage is terminal; a holdout pass promotes to live_strategies (disabled)

  Research and parameter selection happen outside Opus (auro_research); only
  the finished rule comes here to be validated and promoted.
  """

  require Logger
  import Ecto.Query

  alias Ecto.Multi
  alias Opus.Auro.Client, as: Auro
  alias Opus.Pipeline.{BacktestWorker, StrategyConfig, StrategyEvaluation}
  alias Opus.Repo

  @type pipeline_status_row :: %{
          config_id: Ecto.UUID.t(),
          instrument: String.t(),
          granularity: String.t(),
          strategy_type: String.t(),
          parameters: map() | nil,
          source: String.t() | nil,
          inserted_at: DateTime.t(),
          stage: String.t() | nil,
          status: String.t() | nil,
          stats: map() | nil,
          failure_reason: String.t() | nil,
          evaluated_at: DateTime.t() | nil
        }

  @doc """
  Insert a new strategy config and kick off the backtest stage.

  `attrs` must include: instrument, granularity, strategy_type, parameters.

  Returns `{:ok, config}` or `{:error, reason}`.
  """
  @spec submit_config(map()) :: {:ok, StrategyConfig.t()} | {:error, term()}
  def submit_config(attrs) do
    changeset = StrategyConfig.changeset(%StrategyConfig{}, attrs)

    multi =
      Multi.new()
      |> Multi.insert(:config, changeset)
      |> Multi.insert(:backtest_job, fn %{config: config} ->
        BacktestWorker.new(%{config_id: to_string(config.id)})
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

  Goes through the Rust engine's create endpoint — the single write path for
  live strategies — which validates the config and loads the instrument's
  candle buffers so the strategy can evaluate as soon as it is enabled.

  Idempotent: if the (instrument, strategy_type, parameters) combination already
  exists, Rust answers 409 and {:ok, :already_promoted} is returned.
  """
  @spec promote_to_live(String.t()) ::
          {:ok, :promoted | :already_promoted} | {:error, :not_found | term()}
  def promote_to_live(config_id) do
    case Repo.get(StrategyConfig, config_id) do
      nil ->
        {:error, :not_found}

      config ->
        case Auro.create_live_strategy(%{
               strategy_type: config.strategy_type,
               instrument: config.instrument,
               granularity: config.granularity,
               parameters: config.parameters
             }) do
          {:ok, _body} ->
            Logger.info(
              "[Pipeline] Promoted config #{config_id} to live_strategies (disabled) — " <>
                "#{config.strategy_type} #{config.instrument} #{config.granularity}"
            )

            {:ok, :promoted}

          {:error, {:http_error, 409, _body}} ->
            Logger.info(
              "[Pipeline] Config #{config_id} already in live_strategies, skipping promotion"
            )

            {:ok, :already_promoted}

          {:error, reason} ->
            Logger.error("[Pipeline] Promotion of config #{config_id} failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  @doc """
  List all configs and their current evaluation status across all stages.
  Returns a list of maps with config + evaluation rows joined.
  """
  @spec list_pipeline_status() :: [pipeline_status_row()]
  def list_pipeline_status do
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
