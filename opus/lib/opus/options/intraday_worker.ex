defmodule Opus.Options.IntradayWorker do
  @moduledoc """
  Every 15 minutes in the New York session (config.exs): quote the paper
  books' open contracts, one Rust call per underlying
  (`POST /api/questrade/options/quotes`, three Questrade calls each), then
  fill the take-profits those quotes reach (`Opus.Options.Paper.take_profits/1`).
  Only the contracts held are quoted, not whole chains, and the alerts go
  to Discord straight after (`NotifyWorker.send_now/1`). Shares the paper
  books' `enabled` switch; does nothing on a day the US market is closed
  (`Opus.MarketCalendar`).
  """

  use Oban.Worker, queue: :market_data, max_attempts: 1, unique: [period: 10 * 60]

  require Logger

  alias Opus.Auro.Client
  alias Opus.Dashboard.NotifyWorker
  alias Opus.{Clock, MarketCalendar}
  alias Opus.Options.Paper

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{scheduled_at: scheduled_at}) do
    cond do
      not Application.fetch_env!(:opus, Opus.Options.PaperWorker)[:enabled] ->
        :ok

      not MarketCalendar.trading_day?(Clock.date(scheduled_at)) ->
        Logger.info("[PaperIntraday] The US market is closed today; nothing quoted")

      true ->
        Enum.each(Paper.open_contracts(), fn {symbol, ids} -> quote_contracts(symbol, ids) end)

        for {book, _id, fills} <- Paper.take_profits(),
            do:
              Logger.info("[PaperIntraday] #{book}: #{Enum.map_join(fills, ", ", &elem(&1, 0))}")

        NotifyWorker.send_now("options_intraday")
    end

    :ok
  end

  # A failed underlying is logged and skipped: the fills then use its
  # latest quote from earlier today.
  defp quote_contracts(symbol, ids) do
    case Client.quote_option_contracts(symbol, ids) do
      {:ok, %{"missing" => [_ | _] = missing}} ->
        Logger.warning("[PaperIntraday] #{symbol}: no quote for contracts #{inspect(missing)}")

      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("[PaperIntraday] #{symbol} quotes failed: #{inspect(reason)}")
    end
  end
end
