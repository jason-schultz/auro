defmodule Opus.MarketData.QuestradeBarsWorker do
  @moduledoc """
  Daily job: has Rust persist recent Questrade intraday bars for every
  listing flagged `feed_questrade_bars` in the instruments table, and every
  listing held on Wealthsimple, building history beyond Questrade's
  ~3-month retention. Each run re-fetches the last `days` days, so a missed
  run heals on the next one. Held listings no other feed covers daily
  (Canadian ones) also get their daily bars, `daily_days` back.

  All Questrade access goes through Rust's client (the single holder of the
  rotating refresh token) — this worker only calls Auro's HTTP endpoint.
  """

  use Oban.Worker, queue: :market_data, max_attempts: 3

  require Logger

  alias Opus.Auro.Client
  alias Opus.Instruments

  # Minutes between retries, not Oban's seconds-scale default, so an engine
  # restart or a code reload can't burn every attempt in under a minute.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: attempt * 5 * 60

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: args}) do
    config = Application.fetch_env!(:opus, __MODULE__)
    days = Map.get(args, "days", Keyword.fetch!(config, :days))

    intraday =
      for symbol <- Instruments.feed_symbols(:questrade_bars),
          granularity <- Keyword.fetch!(config, :granularities),
          do: {symbol, granularity, days}

    daily =
      for symbol <- Instruments.feed_symbols(:questrade_daily),
          do: {symbol, "D", Keyword.fetch!(config, :daily_days)}

    failures =
      for {symbol, granularity, days} <- intraday ++ daily,
          result = Client.persist_questrade_candles(symbol, granularity, days),
          not match?({:ok, _}, result),
          do: {symbol, granularity, result}

    case failures do
      [] ->
        Logger.info("[QuestradeBars] Persisted flagged listings' bars (#{days} days)")
        :ok

      failures ->
        Logger.error(
          "[QuestradeBars] #{length(failures)} symbol fetches failed: #{inspect(failures)}"
        )

        {:error, {:failed_symbols, Enum.map(failures, fn {s, g, _} -> {s, g} end)}}
    end
  end
end
