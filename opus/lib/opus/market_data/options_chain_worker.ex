defmodule Opus.MarketData.OptionsChainWorker do
  @moduledoc """
  Nightly US option chains from Massive, persisted by Rust.

  Two job shapes share this worker, like `MassiveBarsWorker`:

    * no args (the nightly cron) — fan out one job per configured underlying;
    * `%{"underlying" => _}` — sync that underlying's near-the-money
      contracts (`POST /api/massive/options/contracts/sync`), then fetch the
      last `days` days of daily bars for them
      (`POST /api/massive/options/bars/persist`).

  Runs after `MassiveBarsWorker` because the strike band is centred on the
  underlying's last stored daily close. Bars are one vendor call per
  contract, and SPY alone lists over 2,000 contracts inside ten days, so on
  the free plan (five calls a minute) one underlying takes hours and would
  hold the single-worker `market_data` queue for days. The cron fan-out is
  therefore gated on `enabled: true`, to be set together with an unlimited
  plan (`MASSIVE_CALLS_PER_MINUTE=0` on the Rust side). The two-year history
  is a separate flat-file load, not this worker's job.
  """

  use Oban.Worker,
    queue: :market_data,
    max_attempts: 3,
    unique: [period: 20 * 3600, keys: [:underlying]]

  require Logger

  alias Opus.Auro.Client

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"underlying" => underlying}}) do
    opts = [
      max_days_to_expiry: config(:max_days_to_expiry),
      strike_band_pct: config(:strike_band_pct)
    ]

    with {:ok, contracts} <- Client.sync_option_contracts(underlying, opts),
         {:ok, bars} <- Client.persist_option_bars(underlying, config(:days), opts) do
      Logger.info(
        "[OptionsChain] #{underlying}: #{contracts["contracts_stored"]} contracts, " <>
          "#{bars["bars_stored"]} bars for #{bars["contracts"]} contracts " <>
          "(#{length(bars["failed_contracts"] || [])} failed)"
      )

      :ok
    else
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

  @doc "Enqueue one job per configured underlying."
  @spec enqueue_all() :: {:ok, non_neg_integer()}
  def enqueue_all do
    jobs = for underlying <- config(:underlyings), do: new(%{underlying: underlying})
    inserted = Oban.insert_all(jobs)
    {:ok, length(inserted)}
  end

  defp config(key) do
    :opus |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(key)
  end
end
