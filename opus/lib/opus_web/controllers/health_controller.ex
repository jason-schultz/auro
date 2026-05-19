defmodule OpusWeb.HealthController do
  use OpusWeb, :controller

  import Ecto.Query

  alias Opus.Auro.Client, as: Auro
  alias Opus.Repo
  alias Opus.Trading.{Reconciler, RegimeDetector, RulesEngine}

  def system(conn, _params) do
    now = DateTime.utc_now()

    rust =
      case Auro.get_live_health() do
        {:ok, body} -> body
        {:error, reason} -> %{"error" => inspect(reason)}
      end

    opus_uptime_seconds =
      case :erlang.statistics(:wall_clock) do
        {ms, _} -> div(ms, 1000)
      end

    reconciler_last_run = Reconciler.last_run()
    regime_last_poll = RegimeDetector.last_run()
    rules_last_push = RulesEngine.last_run()

    {nav, pnl_today, pnl_today_pct} = fetch_nav_and_today_pnl(now)

    json(conn, %{
      nav: nav,
      pnl_today: pnl_today,
      pnl_today_pct: pnl_today_pct,
      rust: rust,
      opus: %{
        uptime_seconds: opus_uptime_seconds,
        reconciler_last_run_seconds_ago: age_seconds(now, reconciler_last_run),
        regime_detector_last_poll_seconds_ago: age_seconds(now, regime_last_poll),
        rules_engine_last_push_seconds_ago: age_seconds(now, rules_last_push)
      }
    })
  end

  defp age_seconds(_now, nil), do: nil
  defp age_seconds(now, ts), do: max(DateTime.diff(now, ts, :second), 0)

  defp fetch_nav_and_today_pnl(now) do
    start_of_day = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")

    latest_nav = latest_nav_value() || 0.0
    first_today_nav = first_nav_since(start_of_day) || latest_nav

    pnl_today = latest_nav - first_today_nav
    pnl_today_pct = if first_today_nav > 0, do: pnl_today / first_today_nav * 100.0, else: 0.0

    {latest_nav, pnl_today, pnl_today_pct}
  end

  defp latest_nav_value do
    from(s in "account_snapshots",
      order_by: [desc: s.timestamp],
      limit: 1,
      select: s.nav
    )
    |> Repo.one()
  end

  defp first_nav_since(ts) do
    from(s in "account_snapshots",
      where: s.timestamp >= ^ts,
      order_by: [asc: s.timestamp],
      limit: 1,
      select: s.nav
    )
    |> Repo.one()
  end
end
