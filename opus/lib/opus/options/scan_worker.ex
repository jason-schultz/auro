defmodule Opus.Options.ScanWorker do
  @moduledoc """
  Runs `Opus.Options.Scan` after each chain snapshot: a heads-up before the
  open, then again on the 10:00 New York quotes before the paper books
  trade. Gated on `enabled`.
  """

  use Oban.Worker, queue: :market_data, max_attempts: 2, unique: [period: 30 * 60]

  require Logger

  alias Opus.Options.Scan

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    if Application.fetch_env!(:opus, __MODULE__)[:enabled] do
      {:ok, count} = Scan.run()
      Logger.info("[OptionsScan] Recorded #{count} ideas")
    else
      Logger.info("[OptionsScan] Disabled in config; nothing scanned")
    end

    :ok
  end
end
