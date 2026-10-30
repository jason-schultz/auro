defmodule Opus.Options.ScanWorker do
  @moduledoc """
  Runs `Opus.Options.Scan` after each chain snapshot: a heads-up before the
  open, then again on the 10:00 New York quotes before the paper books
  trade. Gated on `enabled`; does nothing on a day the US market is closed
  (`Opus.MarketCalendar`). Fails when any underlying errored, so Oban
  retries it and the dashboard says so.
  """

  use Oban.Worker, queue: :market_data, max_attempts: 2, unique: [period: 30 * 60]

  require Logger

  alias Opus.{Clock, MarketCalendar}
  alias Opus.Options.Scan

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, String.t()}
  def perform(%Oban.Job{scheduled_at: scheduled_at}) do
    cond do
      not Application.fetch_env!(:opus, __MODULE__)[:enabled] ->
        Logger.info("[OptionsScan] Disabled in config; nothing scanned")

      not MarketCalendar.trading_day?(Clock.date(scheduled_at)) ->
        Logger.info("[OptionsScan] The US market is closed today; nothing scanned")

      true ->
        scan(Clock.date(scheduled_at))
    end
  end

  # An underlying that errored fails the job: Oban retries it and the
  # dashboard shows the failure. The others' ideas are already recorded.
  defp scan(scanned_on) do
    case Scan.run(scanned_on) do
      {:ok, count} ->
        Logger.info("[OptionsScan] Recorded #{count} ideas")

      {:error, words} = error ->
        Logger.error("[OptionsScan] #{words}")
        error
    end
  end
end
