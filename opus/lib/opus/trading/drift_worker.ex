defmodule Opus.Trading.DriftWorker do
  @moduledoc """
  After the US close on trading days (config.exs): check every switched-on
  strategy against its backtest (`Opus.Trading.DriftCheck`). A strategy
  that has stopped behaving like its backtest shows on the dashboard and
  goes to Discord with the next alert run.
  """

  use Oban.Worker, queue: :market_data, max_attempts: 2, unique: [period: 3600]

  import Ecto.Query

  require Logger

  alias Opus.Repo
  alias Opus.Trading.{DriftCheck, LiveStrategy}

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    strategies = from(s in LiveStrategy, where: s.enabled == true and not is_nil(s.strategy_id))

    for strategy <- Repo.all(strategies) do
      case DriftCheck.run(strategy) do
        {:ok, check} ->
          Logger.info("[Drift] #{strategy.instrument} #{strategy.granularity}: #{check.verdict}")

        {:error, reason} ->
          Logger.warning(
            "[Drift] #{strategy.instrument} #{strategy.granularity}: #{inspect(reason)}"
          )
      end
    end

    :ok
  end
end
