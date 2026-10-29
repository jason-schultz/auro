defmodule Opus.Pipeline.WalkForwardWorker do
  @moduledoc """
  Executes the walk-forward stage. Pass → MonteCarloWorker; fail → terminal.
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
  alias Opus.Pipeline.MonteCarloWorker

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"config_id" => config_id}}) do
    Logger.info("[Pipeline] Running walk_forward for config #{config_id}")

    case Client.run_pipeline_walk_forward(config_id) do
      {:ok, %{"status" => "passed"} = result} ->
        Logger.info(
          "[Pipeline] Walk-forward passed for config #{config_id} — " <>
            "oos_sharpe=#{get_in(result, ["stats", "oos_sharpe"])}, " <>
            "sharpe_retention=#{get_in(result, ["stats", "sharpe_retention"])}"
        )

        {:ok, _job} = Oban.insert(MonteCarloWorker.new(%{config_id: config_id}))
        :ok

      {:ok, %{"status" => "failed", "failure_reason" => reason}} ->
        Logger.info("[Pipeline] Walk-forward failed for config #{config_id}: #{reason}")
        :ok

      {:error, reason} ->
        Logger.error(
          "[Pipeline] Walk-forward request failed for config #{config_id}: #{inspect(reason)}"
        )

        {:error, reason}

      other ->
        Logger.error(
          "[Pipeline] Walk-forward returned unexpected response for config #{config_id}: #{inspect(other)}"
        )

        {:error, :unexpected_walk_forward_response}
    end
  end
end
