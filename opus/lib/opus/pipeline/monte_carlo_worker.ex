defmodule Opus.Pipeline.MonteCarloWorker do
  @moduledoc """
  Executes the monte-carlo stage. On pass, logs the result for manual review.
  On failure, enqueues OllamaIterationWorker.
  """

  use Oban.Worker, queue: :pipeline, max_attempts: 3

  require Logger

  alias Opus.Auro.Client
  alias Opus.Pipeline.{Coordinator, OllamaIterationWorker}

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"config_id" => config_id, "depth" => depth}}) do
    Logger.info("[Pipeline] Running monte_carlo for config #{config_id} (depth=#{depth})")

    case Client.run_pipeline_monte_carlo(config_id) do
      {:ok, %{"status" => "passed"} = result} ->
        Logger.info(
          "[Pipeline] Monte Carlo PASSED for config #{config_id} at depth=#{depth} — " <>
            "profitable_pct=#{get_in(result, ["stats", "profitable_pct"])}, " <>
            "median_sharpe=#{get_in(result, ["stats", "median_sharpe"])}, " <>
            "p95_drawdown=#{get_in(result, ["stats", "p95_drawdown"])}"
        )

        Coordinator.promote_to_live(config_id)

        :ok

      {:ok, %{"status" => "failed", "failure_reason" => reason} = result} ->
        stats = Map.get(result, "stats", %{})

        Logger.info(
          "[Pipeline] Monte Carlo failed for config #{config_id}: #{reason} — enqueuing Ollama iteration"
        )

        {:ok, _job} =
          Oban.insert(
            OllamaIterationWorker.new(%{
              config_id: config_id,
              depth: depth,
              failure_reason: reason,
              stats: stats
            })
          )

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
