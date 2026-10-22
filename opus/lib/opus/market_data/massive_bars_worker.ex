defmodule Opus.MarketData.MassiveBarsWorker do
  @moduledoc """
  US equity daily bars from Massive (formerly Polygon), persisted by Rust.

  Two job shapes share this worker:

    * no args (the nightly cron) — fan out one job per (symbol, granularity)
      from config, each re-fetching the last `days` days so a missed night
      heals on the next;
    * `%{"symbol" => _, "granularity" => _, "days" => _}` — one symbol, one
      call to Rust's `POST /api/massive/candles/persist`.

  Fanning out keeps retries per symbol and lets Rust's client pace the calls
  to the plan's five-per-minute limit without one giant job. The free plan
  serves roughly two years of daily bars and no intraday bars; US intraday
  stays on the Questrade worker.

  Massive owns US symbols at D; Questrade owns everything Canadian and the US
  intraday watchlist. Symbol lists live in config (`watchlist`), mirrored from
  `auro_research/data/yahoo/universes.py` (SP100 + US_ETF).
  """

  use Oban.Worker,
    queue: :market_data,
    max_attempts: 3,
    unique: [period: 20 * 3600, keys: [:symbol, :granularity]]

  require Logger

  alias Opus.Auro.Client

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"symbol" => symbol, "granularity" => granularity} = args}) do
    days = Map.get(args, "days", default_days())

    case Client.persist_massive_candles(symbol, granularity, days) do
      {:ok, result} ->
        Logger.info(
          "[MassiveBars] #{symbol} #{granularity}: stored #{result["candles_stored"]} bars (#{days} days)"
        )

        :ok

      {:error, reason} ->
        Logger.error("[MassiveBars] #{symbol} #{granularity} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    {:ok, count} = enqueue_all(default_days())
    Logger.info("[MassiveBars] Enqueued #{count} symbol jobs")
    :ok
  end

  @doc """
  Enqueue one job per configured (symbol, granularity) fetching `days` back.
  The nightly cron uses the configured `days`; a one-off backfill passes the
  plan window, e.g. `enqueue_all(740)`.
  """
  @spec enqueue_all(pos_integer()) :: {:ok, non_neg_integer()}
  def enqueue_all(days) when is_integer(days) and days > 0 do
    jobs =
      for symbol <- config(:watchlist),
          granularity <- config(:granularities),
          do: new(%{symbol: symbol, granularity: granularity, days: days})

    inserted = Oban.insert_all(jobs)
    {:ok, length(inserted)}
  end

  defp default_days, do: config(:days)

  defp config(key) do
    :opus |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(key)
  end
end
