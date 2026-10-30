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

  # Seconds to wait when the tester (which backtests each strategy) is down.
  @tester_wait 900

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:snooze, pos_integer()}
  def perform(%Oban.Job{}) do
    strategies = from(s in LiveStrategy, where: s.enabled == true and not is_nil(s.strategy_id))

    Enum.reduce_while(Repo.all(strategies), :ok, fn strategy, :ok ->
      case DriftCheck.run(strategy) do
        {:ok, check} ->
          Logger.info("[Drift] #{strategy.instrument} #{strategy.granularity}: #{check.verdict}")
          {:cont, :ok}

        # No strategy can be checked without the tester: try the whole run
        # again later instead of logging one failure per strategy.
        {:error, :tester_down} ->
          Logger.warning("[Drift] Tester down; checking again in #{@tester_wait}s")
          {:halt, {:snooze, @tester_wait}}

        {:error, reason} ->
          Logger.warning(
            "[Drift] #{strategy.instrument} #{strategy.granularity}: #{inspect(reason)}"
          )

          {:cont, :ok}
      end
    end)
  end
end
