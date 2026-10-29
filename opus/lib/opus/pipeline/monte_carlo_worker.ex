defmodule Opus.Pipeline.MonteCarloWorker do
  @moduledoc """
  Executes the Monte Carlo stage. Pass → HoldoutWorker (the sealed-window
  look; promotion happens there); fail → terminal.
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
  alias Opus.Pipeline.HoldoutWorker

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"config_id" => config_id}}) do
    Logger.info("[Pipeline] Running monte_carlo for config #{config_id}")

    case Client.run_pipeline_monte_carlo(config_id) do
      {:ok, %{"status" => "passed"} = result} ->
        Logger.info(
          "[Pipeline] Monte Carlo passed for config #{config_id} — " <>
            "profitable_pct=#{get_in(result, ["stats", "profitable_pct"])}, " <>
            "median_sharpe=#{get_in(result, ["stats", "median_sharpe"])}, " <>
            "p95_drawdown=#{get_in(result, ["stats", "p95_drawdown"])}"
        )

        {:ok, _job} = Oban.insert(HoldoutWorker.new(%{config_id: config_id}))
        :ok

      {:ok, %{"status" => "failed", "failure_reason" => reason}} ->
        Logger.info("[Pipeline] Monte Carlo failed for config #{config_id}: #{reason}")
        :ok

      {:error, reason} ->
        Logger.error(
          "[Pipeline] Monte Carlo request failed for config #{config_id}: #{inspect(reason)}"
        )

        {:error, reason}

      other ->
        Logger.error(
          "[Pipeline] Monte Carlo returned unexpected response for config #{config_id}: #{inspect(other)}"
        )

        {:error, :unexpected_monte_carlo_response}
    end
  end
end
