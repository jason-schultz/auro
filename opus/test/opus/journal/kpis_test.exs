defmodule Opus.Journal.KpisTest do
  use Opus.DataCase, async: false

  alias Opus.Journal
  alias Opus.Repo
  alias Opus.Trading.LiveTrade

  setup do
    Repo.delete_all(LiveTrade)
    :ok
  end

  defp closed!(pnl, pnl_percent) do
    now = DateTime.utc_now()

    Repo.insert!(%LiveTrade{
      instrument: "AUD_CAD",
      status: "closed",
      pnl: pnl,
      pnl_percent: pnl_percent,
      exit_time: DateTime.add(now, -3600, :second),
      created_at: now,
      updated_at: now
    })
  end

  test "a trade with no money recorded counts by its price move, not as a scratch" do
    closed!(50.0, 0.004)
    # An old stop-out whose money was never recorded.
    closed!(nil, -0.0017)

    now = DateTime.utc_now()
    kpis = Journal.kpis({DateTime.add(now, -86_400, :second), now})

    assert kpis.trade_count == 2
    assert kpis.win_count == 1
    assert kpis.loss_count == 1
    assert kpis.breakeven_count == 0
    assert kpis.win_rate_pct == 50.0
  end
end
