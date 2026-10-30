defmodule Opus.Pipeline.BacktestWorker do
  @moduledoc """
  Executes the backtest stage. Pass → WalkForwardWorker; fail → terminal.
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
  alias Opus.Pipeline.WalkForwardWorker

  # Seconds between looks while the tester is down.
  @tester_wait 60

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:snooze, pos_integer()} | {:error, term()}
  def perform(%Oban.Job{args: %{"config_id" => config_id}}) do
    Logger.info("[Pipeline] Running backtest for config #{config_id}")

    case Client.run_pipeline_backtest(config_id) do
      {:ok, %{"status" => "passed"} = result} ->
        Logger.info(
          "[Pipeline] Backtest passed for config #{config_id} — " <>
            "sharpe=#{get_in(result, ["stats", "sharpe"])}, " <>
            "num_trades=#{get_in(result, ["stats", "num_trades"])}"
        )

        {:ok, _job} = Oban.insert(WalkForwardWorker.new(%{config_id: config_id}))
        :ok

      {:ok, %{"status" => "failed", "failure_reason" => reason}} ->
        Logger.info("[Pipeline] Backtest failed for config #{config_id}: #{reason}")
        :ok

      # The tester isn't running: wait for it rather than fail the
      # strategy (a snooze doesn't use up the one attempt).
      {:error, :tester_down} ->
        Logger.warning("[Pipeline] Tester down; #{config_id} waits #{@tester_wait}s")
        {:snooze, @tester_wait}

      {:error, reason} ->
        Logger.error(
          "[Pipeline] Backtest request failed for config #{config_id}: #{inspect(reason)}"
        )

        {:error, reason}

      other ->
        Logger.error(
          "[Pipeline] Backtest returned unexpected response for config #{config_id}: #{inspect(other)}"
        )

        {:error, :unexpected_backtest_response}
    end
  end
end
