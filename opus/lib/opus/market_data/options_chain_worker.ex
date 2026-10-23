defmodule Opus.MarketData.OptionsChainWorker do
  @moduledoc """
  Nightly option chain snapshots from Questrade, persisted by Rust.

  Two job shapes share this worker, like `MassiveBarsWorker`:

    * no args (the nightly cron) — fan out one job per listing flagged
      `feed_options_chain` in the instruments table;
    * `%{"underlying" => _}` — capture that underlying's near-the-money
      chain (`POST /api/questrade/options/snapshot`): the contracts into
      `option_contracts`, tonight's quotes with the exchange greeks into
      `option_quotes`.

  Runs after the close, when the quotes are the day's closing values, so
  Questrade's data delay does not matter. The strike band is centred on the
  underlying's Questrade quote at capture time, not on stored bars. The
  cron fan-out is gated on `enabled`. Historical bars are the Massive
  flat-file path, not this worker's job.
  """

  use Oban.Worker,
    queue: :market_data,
    max_attempts: 3,
    unique: [period: 20 * 3600, keys: [:underlying]]

  require Logger

  alias Opus.Auro.Client
  alias Opus.Instruments

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

  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    if config(:enabled) do
      {:ok, count} = enqueue_all()
      Logger.info("[OptionsChain] Enqueued #{count} underlying jobs")
    else
      Logger.info("[OptionsChain] Disabled in config; nothing enqueued")
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
