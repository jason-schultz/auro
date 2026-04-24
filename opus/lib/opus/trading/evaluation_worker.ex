defmodule Opus.Trading.EvaluationWorker do
  use Oban.Worker, queue: :evaluations, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"granularity" => granularity}}) do
    require Logger

    Logger.info("EvaluationWorker fired for granularity=#{granularity}")
    :ok
  end
end
