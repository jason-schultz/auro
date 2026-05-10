defmodule Opus.Pipeline.WalkForwardWorker do
  @moduledoc """
  Executes the walk-forward stage and enqueues monte-carlo on success,
  or OllamaIterationWorker on failure.
  """

  use Oban.Worker, queue: :pipeline, max_attempts: 3

  require Logger

  alias Opus.Auro.Client
  alias Opus.Pipeline.{MonteCarloWorker, OllamaIterationWorker}

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"config_id" => config_id, "depth" => depth}}) do
    Logger.info("[Pipeline] Running walk_forward for config #{config_id} (depth=#{depth})")

    case Client.run_pipeline_walk_forward(config_id) do
      {:ok, %{"status" => "passed"} = result} ->
        Logger.info(
          "[Pipeline] Walk-forward passed for config #{config_id} — " <>
            "oos_sharpe=#{get_in(result, ["stats", "oos_sharpe"])}, " <>
            "sharpe_retention=#{get_in(result, ["stats", "sharpe_retention"])}"
        )

        {:ok, _job} = Oban.insert(MonteCarloWorker.new(%{config_id: config_id, depth: depth}))
        :ok

      {:ok, %{"status" => "failed", "failure_reason" => reason} = result} ->
        stats = Map.get(result, "stats", %{})

        Logger.info(
          "[Pipeline] Walk-forward failed for config #{config_id}: #{reason} — enqueuing Ollama iteration"
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
