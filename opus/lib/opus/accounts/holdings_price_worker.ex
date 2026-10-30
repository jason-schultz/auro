defmodule Opus.Accounts.HoldingsPriceWorker do
  @moduledoc """
  Every 15 minutes in the New York session (config.exs): re-price the
  Wealthsimple holdings from Questrade quotes
  (`POST /api/brokers/wealthsimple/refresh-prices`), so the Accounts page
  shows what they're worth now, not as of the last manual refresh. Does
  nothing outside 09:30–16:00 New York or on a day the US market is closed
  (`Opus.MarketCalendar`); Canadian exchanges keep the same hours.
  """

  use Oban.Worker, queue: :market_data, max_attempts: 1, unique: [period: 10 * 60]

  require Logger

  alias Opus.Auro.Client
  alias Opus.{Clock, MarketCalendar}

  @open ~T[09:30:00]
  # The 16:00 run takes the closing prices.
  @close ~T[16:00:00]

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{scheduled_at: scheduled_at}) do
    if in_session?(scheduled_at), do: refresh(), else: :ok
  end

  @doc "Whether `utc` falls in a New York trading session, close included."
  @spec in_session?(DateTime.t()) :: boolean()
  def in_session?(utc) do
    local = Clock.local(utc)
    time = DateTime.to_time(local)

    MarketCalendar.trading_day?(DateTime.to_date(local)) and
      Time.compare(time, @open) != :lt and Time.compare(time, @close) != :gt
  end

  defp refresh do
    case Client.refresh_wealthsimple_prices() do
      {:ok, result} ->
        Logger.info("[HoldingsPrices] Re-priced #{result["updated"]} Wealthsimple positions")

      {:error, reason} ->
        Logger.error("[HoldingsPrices] Re-pricing failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
