defmodule Opus.Pipeline.OllamaIterationWorker do
  @moduledoc """
  Calls Ollama to revise strategy parameters after a pipeline stage failure,
  then submits a new child config into the pipeline.

  Depth is threaded from the originating Coordinator.submit_config/1 call through
  every worker. When depth reaches max_depth the chain stops gracefully.
  """

  use Oban.Worker, queue: :ollama, max_attempts: 3

  require Logger

  alias Opus.Ollama.Client, as: OllamaClient
  alias Opus.Pipeline.{Coordinator, StrategyConfig, StrategyEvaluation}
  alias Opus.Repo

  @max_depth 10

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{
        args: %{
          "config_id" => config_id,
          "depth" => depth,
          "failure_reason" => failure_reason,
          "stats" => stats
        }
      }) do
    if depth >= @max_depth do
      Logger.info(
        "[Pipeline] Max depth #{@max_depth} reached for config #{config_id}, stopping iteration"
      )

      :ok
    else
      case Repo.get(StrategyConfig, config_id) do
        nil ->
          Logger.error("[Pipeline] OllamaIteration: config #{config_id} not found")
          {:error, :config_not_found}

        config ->
          run_iteration(config, depth, failure_reason, stats)
      end
    end
  end

  defp run_iteration(config, depth, failure_reason, stats) do
    Logger.info(
      "[Pipeline] Ollama iteration depth=#{depth} for config #{config.id} " <>
        "(#{config.strategy_type} #{config.instrument} #{config.granularity})"
    )

    parent_context = build_parent_context(config, stats)
    context = %{failure_reason: failure_reason, stats: stats}

    case OllamaClient.generate_revised_parameters(config.strategy_type, config.parameters, context, parent_context) do
      {:ok, revised_params, prompt} ->
        opts = %{parameters: revised_params, depth: depth + 1, generation_prompt: prompt}

        case Coordinator.submit_iteration(config, opts) do
          {:ok, new_config} ->
            Logger.info(
              "[Pipeline] Ollama revised config #{new_config.id} at depth=#{depth + 1} " <>
                "(parent: #{config.id})"
            )

            :ok

          {:error, :unchanged_parameters} ->
            Logger.info(
              "[Pipeline] Params already seen in lineage for config #{config.id}, stopping chain"
            )

            :ok

          {:error, reason} ->
            Logger.error(
              "[Pipeline] Failed to submit Ollama iteration for config #{config.id}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, :unchanged_parameters} ->
        Logger.info(
          "[Pipeline] Ollama returned unchanged parameters for config #{config.id}, stopping chain"
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "[Pipeline] Ollama parameter generation failed for config #{config.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp build_parent_context(config, current_stats) do
    case config.parent_config_id do
      nil ->
        nil

      parent_id ->
        import Ecto.Query

        case Repo.get(StrategyConfig, parent_id) do
          nil ->
            nil

          parent ->
            parent_eval =
              Repo.one(
                from e in StrategyEvaluation,
                  where: e.strategy_config_id == ^parent.id and e.stage == "backtest",
                  limit: 1
              )

            if parent_eval && parent_eval.stats do
              %{params: parent.parameters, stats: parent_eval.stats, current_stats: current_stats}
            else
              nil
            end
        end
    end
  end
end
