defmodule Opus.Pipeline.HoldoutWorker do
  @moduledoc """
  Executes the sealed-holdout stage: the one look at bars the exploration
  stages never saw, taken only after a config has passed backtest,
  walk-forward and Monte Carlo (and, for evo lineages, won its lineage).

    - pass → `PromoteWorker` adds it to live_strategies (disabled; you switch
      it on). Promotion is its own job so a failed promote retries without
      taking the holdout look again.
    - fail → terminal. The verdict is final: a failed config is not re-run
      against the same window, and the Rust side records every look so
      `holdout_looks` in the stats shows how many siblings have been judged on it.
  """

  # One attempt: a stage isn't re-run on its own (opus/AGENTS.md). Unique
  # per config while a run is waiting or running, so a double enqueue
  # doesn't run the stage twice.
  use Oban.Worker,
    queue: :pipeline,
    max_attempts: 1,
    unique: [keys: [:config_id], period: :infinity, states: :incomplete]

  require Logger

  alias Opus.Auro.Client
  alias Opus.Pipeline.PromoteWorker

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"config_id" => config_id}}) do
    Logger.info("[Pipeline] Running holdout for config #{config_id}")

    case Client.run_pipeline_holdout(config_id) do
      {:ok, %{"status" => "passed", "stats" => stats}} ->
        Logger.info(
          "[Pipeline] Holdout PASSED for config #{config_id} — " <>
            "annual_sharpe=#{stats["annual_sharpe"]}, total_return=#{stats["total_return"]}, " <>
            "num_trades=#{stats["num_trades"]}, holdout_looks=#{stats["holdout_looks"]}"
        )

        {:ok, _job} = Oban.insert(PromoteWorker.new(%{config_id: config_id}))
        :ok

      {:ok, %{"status" => "failed", "failure_reason" => reason}} ->
        Logger.info("[Pipeline] Holdout failed for config #{config_id}: #{reason}")
        :ok

      {:error, reason} ->
        Logger.error(
          "[Pipeline] Holdout request failed for config #{config_id}: #{inspect(reason)}"
        )

        {:error, reason}

      other ->
        Logger.error(
          "[Pipeline] Holdout returned unexpected response for config #{config_id}: #{inspect(other)}"
        )

        {:error, :unexpected_holdout_response}
    end
  end
end
