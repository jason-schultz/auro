defmodule Opus.MarketData.OptionsChainWorker do
  @moduledoc """
  Option chain snapshots from Questrade, persisted by Rust: 09:00 and
  10:00 New York on trading days (config.exs).

  Two job shapes share this worker, like `MassiveBarsWorker`:

    * no args (the cron) — fan out one job per listing flagged
      `feed_options_chain` in the instruments table;
    * `%{"underlying" => _}` — capture that underlying's near-the-money
      chain (`POST /api/questrade/options/snapshot`): the contracts into
      `option_contracts`, the current quotes with the exchange greeks into
      `option_quotes`.

  The 09:00 run, before the open, holds the previous session's closing
  quotes; the 10:00 run holds live ones, after the opening rush. The strike
  band is centred on the underlying's Questrade quote at capture time, not
  on stored bars. The cron fan-out is gated on `enabled` and does nothing on
  a day the US market is closed (`Opus.MarketCalendar`). Historical bars are the Massive
  flat-file path, not this worker's job.
  """

  use Oban.Worker, queue: :market_data, max_attempts: 3

  require Logger

  alias Opus.Auro.Client
  alias Opus.{Clock, Instruments, MarketCalendar}

  # Two, then four minutes between retries: long enough to ride out an
  # engine restart or a code reload, short enough to land before the scan
  # 15 minutes after the snapshot.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: attempt * 2 * 60

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"underlying" => underlying}}) do
    opts = [
      max_days_to_expiry: config(:max_days_to_expiry),
      strike_band_pct: config(:strike_band_pct)
    ]

    case Client.snapshot_option_chain(underlying, opts) do
      {:ok, snapshot} ->
        Logger.info(
          "[OptionsChain] #{underlying}: #{snapshot["contracts_stored"]} contracts, " <>
            "#{snapshot["quotes_stored"]} quotes at spot #{snapshot["spot"]} " <>
            "(delay ≤ #{snapshot["max_delay_seconds"]}s)"
        )

        :ok

      {:error, reason} ->
        Logger.error("[OptionsChain] #{underlying} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args, scheduled_at: scheduled_at}) when map_size(args) == 0 do
    cond do
      not config(:enabled) ->
        Logger.info("[OptionsChain] Disabled in config; nothing enqueued")

      not MarketCalendar.trading_day?(Clock.date(scheduled_at)) ->
        Logger.info("[OptionsChain] The US market is closed today; nothing enqueued")

      true ->
        {:ok, count} = enqueue_all()
        Logger.info("[OptionsChain] Enqueued #{count} underlying jobs")
    end

    :ok
  end

  @doc "Enqueue one job per listing flagged for option chains."
  @spec enqueue_all() :: {:ok, non_neg_integer()}
  def enqueue_all do
    jobs =
      for underlying <- Instruments.feed_symbols(:options_chain),
          do: new(%{underlying: underlying})

    inserted = Oban.insert_all(jobs)
    {:ok, length(inserted)}
  end

  defp config(key) do
    :opus |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(key)
  end
end
