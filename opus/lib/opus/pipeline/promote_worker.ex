defmodule Opus.Pipeline.PromoteWorker do
  @moduledoc """
  Adds a config that passed its holdout to live_strategies (disabled; you
  switch it on), through `Coordinator.promote_to_live/1`.

  Its own job, unlike the stages, so it can retry: the holdout look is taken
  once, but a promote that failed (the engine down for a moment) is only a
  request to repeat. Promotion is idempotent: an already promoted config
  counts as done.
  """

  use Oban.Worker,
    queue: :pipeline,
    max_attempts: 5,
    unique: [keys: [:config_id], period: :infinity, states: :incomplete]

  alias Opus.Pipeline.Coordinator

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:cancel, term()} | {:error, term()}
  def perform(%Oban.Job{args: %{"config_id" => config_id}}) do
    case Coordinator.promote_to_live(config_id) do
      {:ok, _promoted} -> :ok
      # No such config: retrying can't help.
      {:error, :not_found} -> {:cancel, :not_found}
      # A basket is tested, not traded live: nothing to retry.
      {:error, :basket} -> {:cancel, :basket}
      {:error, reason} -> {:error, reason}
    end
  end
end
