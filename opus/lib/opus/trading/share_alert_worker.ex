defmodule Opus.Trading.ShareAlertWorker do
  @moduledoc """
  The share-alert check at 15:45 New York on trading days
  (`Opus.Trading.ShareAlerts.run/1`): 15 minutes before the close, so an
  alert can be placed before the bar the strategy was tested on closes.
  One attempt: a check retried after the close would alert on a price
  you can no longer get.
  """

  use Oban.Worker, queue: :alerts, max_attempts: 1, unique: [period: 600]

  alias Opus.Trading.ShareAlerts

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(_job), do: ShareAlerts.run()
end
