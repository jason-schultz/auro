defmodule Opus.Options.PaperWorker do
  @moduledoc """
  Runs the options paper books (`Opus.Options.Paper`) after the nightly
  chain snapshot and the ideas scan. Safe to run twice: a night already recorded
  is skipped. Gated on `enabled`.
  """

  use Oban.Worker, queue: :market_data, max_attempts: 2, unique: [period: 20 * 3600]

  require Logger

  alias Opus.Options.Paper

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    if Application.fetch_env!(:opus, __MODULE__)[:enabled] do
      for {book, symbol, result} <- Paper.run(), do: log("#{book} #{symbol}", result)
    else
      Logger.info("[PaperBook] Disabled in config; nothing run")
    end

    :ok
  end

  defp log(name, {:ok, actions}),
    do: Logger.info("[PaperBook] #{name}: #{Enum.map_join(actions, ", ", &elem(&1, 0))}")

  defp log(name, {:skipped, reason}),
    do: Logger.info("[PaperBook] #{name}: skipped (#{reason})")
end
