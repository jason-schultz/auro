defmodule Opus.Pipeline.GridIterationWorker do
  @moduledoc """
  Coordinate descent iteration worker. Replaces OllamaIterationWorker.

  On each backtest failure, generates up to 3 candidate parameter sets by
  varying exactly ONE parameter (determined by depth, cycling through the
  strategy's parameter list). All other parameters are held fixed.

  Each candidate is submitted as a child config via Coordinator.submit_iteration.
  The pipeline naturally prunes: candidates that fail continue iterating,
  candidates that pass advance to walk-forward.
  """

  use Oban.Worker, queue: :ollama, max_attempts: 3

  require Logger

  alias Opus.Pipeline.{Coordinator, GridSearch, StrategyConfig}
  alias Opus.Repo

  @max_depth 12

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{
        args: %{
          "config_id" => config_id,
          "depth" => depth,
          "failure_reason" => failure_reason,
          "stats" => _stats
        }
      }) do
    if depth >= @max_depth do
      Logger.info(
        "[Pipeline] Max depth #{@max_depth} reached for config #{config_id}, stopping"
      )

      :ok
    else
      case Repo.get(StrategyConfig, config_id) do
        nil ->
          Logger.error("[Pipeline] GridIteration: config #{config_id} not found")
          {:error, :config_not_found}

        config ->
          run_iteration(config, depth, failure_reason)
      end
    end
  end

  defp run_iteration(config, depth, failure_reason) do
    Logger.info(
      "[Pipeline] Grid iteration depth=#{depth} for config #{config.id} " <>
        "(#{config.strategy_type} #{config.instrument} #{config.granularity}) " <>
        "— varying #{target_param(config.strategy_type, depth)}"
    )

    case GridSearch.candidates(config.strategy_type, config.parameters, failure_reason, depth + 1) do
      {:error, :exhausted} ->
        Logger.info(
          "[Pipeline] GridSearch exhausted candidates for config #{config.id} at depth=#{depth}"
        )

        :ok

      {:ok, candidates} ->
        submitted =
          Enum.reduce(candidates, 0, fn params, count ->
            opts = %{parameters: params, depth: depth + 1}

            case Coordinator.submit_iteration(config, opts) do
              {:ok, new_config} ->
                Logger.info(
                  "[Pipeline] Submitted grid candidate #{new_config.id} at depth=#{depth + 1} " <>
                    "(parent: #{config.id})"
                )

                count + 1

              {:error, :unchanged_parameters} ->
                count

              {:error, reason} ->
                Logger.error(
                  "[Pipeline] Failed to submit grid candidate for #{config.id}: #{inspect(reason)}"
                )

                count
            end
          end)

        Logger.info(
          "[Pipeline] Submitted #{submitted}/#{length(candidates)} grid candidates " <>
            "for config #{config.id} at depth=#{depth + 1}"
        )

        :ok
    end
  end

  defp target_param("mean_reversion", depth) do
    Enum.at(~w[entry_threshold ma_period exit_threshold stop_loss], rem(depth, 4))
  end

  defp target_param("trend_following", depth) do
    Enum.at(~w[slow_period fast_period stop_loss take_profit], rem(depth, 4))
  end

  defp target_param(_, _), do: "unknown"
end
