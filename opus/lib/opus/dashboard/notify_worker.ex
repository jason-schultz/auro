defmodule Opus.Dashboard.NotifyWorker do
  @moduledoc """
  Sends the dashboard's alerts to Discord (`Opus.Dashboard.Discord`).

  Every 5 minutes, and right after a job that can raise an alert worth
  acting on fast (`send_now/1`: the paper books, the intraday option
  quotes): each alert not sent yet, once. An alert stays sent while
  the dashboard keeps showing it; once it has been gone for an hour it's
  forgotten, so it's sent again if it comes back. The hour keeps an alert
  that flickers (an engine restarting) from pinging every 5 minutes.

  At 16:30 New York on trading days (`%{"check_in" => true}`): the day's
  write-up (`Opus.Dashboard.Summary`), sent even when all is quiet.
  Everything runs on this computer, so no alerts can also mean Opus isn't
  running; a missing day's write-up is how you'd notice. Fridays at 17:00
  (`%{"summary" => "week"}`): the week's.

  Nothing is sent or recorded without a webhook URL.
  """

  use Oban.Worker, queue: :alerts, max_attempts: 1, unique: [period: 240]

  import Ecto.Query

  require Logger

  alias Opus.Dashboard
  alias Opus.Dashboard.{Alerts, Discord, Summary}
  alias Opus.Repo

  @forget_after_seconds 3600

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: args}) do
    if Discord.configured?() do
      run(args, DateTime.utc_now())
    else
      Logger.debug("[Notify] No DISCORD_WEBHOOK_URL; nothing sent")
      :ok
    end
  end

  defp run(%{"check_in" => true}, now), do: post_summary(:day, now)
  defp run(%{"summary" => "week"}, now), do: post_summary(:week, now)

  defp run(_args, now) do
    alerts = now |> Dashboard.gather() |> Map.fetch!(:input) |> Dashboard.alerts()
    notify(alerts, now)
  end

  @doc """
  Queues a send now instead of waiting for the next 5-minute run. `source`
  names the job asking, so one job's send doesn't swallow another's.
  """
  @spec send_now(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def send_now(source), do: %{source: source} |> new() |> Oban.insert()

  @doc """
  Sends the alerts not sent yet, records them, and forgets those gone for
  an hour. Returns `:ok`, or the error that stopped the sending (what went
  out before it is recorded).
  """
  @spec notify([Alerts.alert()], DateTime.t()) :: :ok | {:error, term()}
  def notify(alerts, now) do
    alerts = Enum.filter(alerts, &Alerts.notify?/1)
    keys = alerts |> Enum.map(& &1.key) |> Enum.uniq()
    at = DateTime.to_naive(now)
    known = MapSet.new(Repo.all(from(n in "alert_notifications", select: n.key)))

    from(n in "alert_notifications", where: n.key in type(^keys, {:array, :string}))
    |> Repo.update_all(set: [seen_at: at])

    {sent, result} =
      alerts
      |> Enum.reject(&MapSet.member?(known, &1.key))
      |> Enum.uniq_by(& &1.key)
      |> Discord.post_alerts()

    Repo.insert_all(
      "alert_notifications",
      Enum.map(sent, &%{key: &1, sent_at: at, seen_at: at}),
      on_conflict: :nothing
    )

    forget_before = NaiveDateTime.add(at, -@forget_after_seconds)

    from(n in "alert_notifications", where: n.seen_at < type(^forget_before, :naive_datetime))
    |> Repo.delete_all()

    with {:error, reason} <- result do
      Logger.warning("[Notify] Discord post failed: #{inspect(reason)}")
      {:error, reason}
    end
  end

  defp post_summary(period, now) do
    gathered = Dashboard.gather(now)
    {title, lines} = Summary.build(period, gathered, Dashboard.alerts(gathered.input), now)
    Discord.post_message(title, lines)
  end
end
