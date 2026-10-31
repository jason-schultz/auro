defmodule Opus.Accounts.SnapshotWorker do
  @moduledoc """
  16:10 New York on trading days, after the 16:00 re-price takes the
  closing prices (`Opus.Accounts.HoldingsPriceWorker`): records the
  hand-entered Wealthsimple holdings as the day's close
  (`Opus.Accounts.Snapshots.take/1`), and every broker account's value for
  the net worth line (`take_accounts/2`). Balances come from the engine; if
  it can't answer, the holdings are still recorded and the job retries.
  """

  use Oban.Worker, queue: :market_data, max_attempts: 3

  require Logger

  alias Opus.Accounts
  alias Opus.Accounts.Snapshots
  alias Opus.{Clock, MarketCalendar}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today = Clock.today()

    if MarketCalendar.trading_day?(today) do
      count = Snapshots.take(today)
      Logger.info("[Holdings] Recorded #{count} holdings at #{today}'s close")

      with {:ok, overview} <- Accounts.overview() do
        count = Snapshots.take_accounts(today, overview.accounts)
        Logger.info("[Holdings] Recorded #{count} account values at #{today}'s close")
        :ok
      end
    else
      :ok
    end
  end
end
