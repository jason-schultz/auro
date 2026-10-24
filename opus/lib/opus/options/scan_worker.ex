defmodule Opus.Options.ScanWorker do
  @moduledoc """
  Runs `Opus.Options.Scan` after the nightly chain snapshot has landed, so
  the Options page has that night's ideas by morning. Gated on `enabled`.
  """

  use Oban.Worker, queue: :market_data, max_attempts: 2, unique: [period: 20 * 3600]

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
