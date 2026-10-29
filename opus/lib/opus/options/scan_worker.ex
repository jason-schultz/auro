defmodule Opus.Options.ScanWorker do
  @moduledoc """
  Runs `Opus.Options.Scan` after each chain snapshot: a heads-up before the
  open, then again on the 10:00 New York quotes before the paper books
  trade. Gated on `enabled`; does nothing on a day the US market is closed
  (`Opus.MarketCalendar`).
  """

  use Oban.Worker, queue: :market_data, max_attempts: 2, unique: [period: 30 * 60]

  require Logger

  alias Opus.{Clock, MarketCalendar}
  alias Opus.Options.Scan

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{scheduled_at: scheduled_at}) do
    cond do
      not Application.fetch_env!(:opus, __MODULE__)[:enabled] ->
        Logger.info("[OptionsScan] Disabled in config; nothing scanned")

      not MarketCalendar.trading_day?(Clock.date(scheduled_at)) ->
        Logger.info("[OptionsScan] The US market is closed today; nothing scanned")

      true ->
        {:ok, count} = Scan.run()
        Logger.info("[OptionsScan] Recorded #{count} ideas")
    end

    :ok
  end
end
