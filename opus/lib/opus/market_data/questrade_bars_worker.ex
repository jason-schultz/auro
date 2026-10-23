defmodule Opus.MarketData.QuestradeBarsWorker do
  @moduledoc """
  Daily job: has Rust persist recent Questrade intraday bars for every
  listing flagged `feed_questrade_bars` in the instruments table, building
  history beyond Questrade's ~3-month retention. Each run re-fetches the
  last `days` days, so a missed run heals on the next one.

  All Questrade access goes through Rust's client (the single holder of the
  rotating refresh token) — this worker only calls Auro's HTTP endpoint.
  """

  use Oban.Worker, queue: :market_data, max_attempts: 3

  require Logger

  alias Opus.Auro.Client
  alias Opus.Instruments

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: args}) do
    config = Application.fetch_env!(:opus, __MODULE__)
    days = Map.get(args, "days", Keyword.fetch!(config, :days))

    failures =
      for symbol <- Instruments.feed_symbols(:questrade_bars),
          granularity <- Keyword.fetch!(config, :granularities),
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
