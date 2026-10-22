defmodule Opus.MarketData.FinancingSnapshotWorker do
  @moduledoc """
  Daily job: has Rust record OANDA's current per-instrument financing rates
  (`instrument_financing`), so backtests charge the real overnight cost from
  the day recording started and the policy-rate estimate only before it.

  Runs before the 17:00 New York rollover the rates apply to. OANDA access is
  Rust's; this worker only calls Auro's HTTP endpoint.
  """

  use Oban.Worker, queue: :market_data, max_attempts: 3

  require Logger

  alias Opus.Auro.Client

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{}) do
    case Client.snapshot_financing() do
      {:ok, %{"instruments" => n, "as_of" => as_of}} ->
        Logger.info("[FinancingSnapshot] Recorded rates for #{n} instruments (#{as_of})")
        :ok

      {:ok, body} ->
        Logger.info("[FinancingSnapshot] Recorded rates: #{inspect(body)}")
        :ok

      {:error, reason} ->
        Logger.error("[FinancingSnapshot] Failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
