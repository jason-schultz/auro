defmodule Opus.Pipeline.BacktestWorker do
  @moduledoc """
  Executes the backtest stage and enqueues walk-forward on success,
  or GridIterationWorker on failure.
  """

  use Oban.Worker, queue: :pipeline, max_attempts: 3

  require Logger

  alias Opus.Auro.Client
  alias Opus.Pipeline.{GridIterationWorker, WalkForwardWorker}

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"config_id" => config_id, "depth" => depth}}) do
    Logger.info("[Pipeline] Running backtest for config #{config_id} (depth=#{depth})")

    case Client.run_pipeline_backtest(config_id) do
      {:ok, %{"status" => "passed"} = result} ->
        Logger.info(
          "[Pipeline] Backtest passed for config #{config_id} — " <>
            "sharpe=#{get_in(result, ["stats", "sharpe"])}, " <>
            "num_trades=#{get_in(result, ["stats", "num_trades"])}"
        )

        {:ok, _job} = Oban.insert(WalkForwardWorker.new(%{config_id: config_id, depth: depth}))
        :ok

      {:ok, %{"status" => "failed", "failure_reason" => reason} = result} ->
        stats = Map.get(result, "stats", %{})

        Logger.info(
          "[Pipeline] Backtest failed for config #{config_id}: #{reason} — enqueuing grid iteration"
        )

        {:ok, _job} =
          Oban.insert(
            GridIterationWorker.new(%{
              config_id: config_id,
              depth: depth,
              failure_reason: reason,
              stats: stats
            })
          )

        :ok

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
