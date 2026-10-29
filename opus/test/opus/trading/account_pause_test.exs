defmodule Opus.Trading.AccountPauseTest do
  use Opus.DataCase, async: false

  alias Opus.Repo
  alias Opus.Trading.AccountPause

  setup do
    Repo.delete_all(AccountPause)
    Repo.delete_all("account_snapshots")
    # Measure from well before the snapshots below, whenever the migration ran.
    Repo.query!(
      "UPDATE trading_config SET value = jsonb_set(value, '{since}', '\"2000-01-01T00:00:00Z\"') WHERE key = 'account_limits'"
    )

    :ok
  end

  test "trips at the limit, not before" do
    assert AccountPause.tripped?(100_000, 90_000, 10)
    refute AccountPause.tripped?(100_000, 90_001, 10)
    refute AccountPause.tripped?(0, 0, 10)
  end

  test "a fall past the limit from the peak opens a pause that holds until cleared" do
    now = DateTime.utc_now()
    snapshot(now, -120, 100_000)
    snapshot(now, -60, 95_000)
    assert AccountPause.check(now) == nil

    snapshot(now, -1, 89_000)
    assert %AccountPause{peak_nav: 100_000.0, nav: 89_000.0} = AccountPause.check(now)
    # Still the same pause on the next check, however NAV moves.
    snapshot(now, 0, 99_000)
    assert %AccountPause{nav: 89_000.0} = AccountPause.check(now)

    assert AccountPause.clear() == 1
    assert AccountPause.open() == nil
  end

  test "after a reset the peak starts again from there" do
    now = DateTime.utc_now()
    snapshot(now, -120, 100_000)
    snapshot(now, -60, 89_000)
    assert %AccountPause{} = AccountPause.check(now)

    AccountPause.clear("manual", now)
    snapshot(now, 30, 85_000)

    # 85k is 15% below the old peak, but the peak since the reset is 85k.
    assert AccountPause.check(DateTime.add(now, 60, :second)) == nil
  end

  defp snapshot(now, offset_seconds, nav) do
    Repo.insert_all("account_snapshots", [
      %{
        id: Ecto.UUID.bingenerate(),
        timestamp: DateTime.add(now, offset_seconds, :second),
        nav: nav * 1.0,
        balance: nav * 1.0,
        unrealized_pl: 0.0,
        margin_used: 0.0,
        margin_available: nav * 1.0,
        currency: "CAD",
        open_position_count: 0
      }
    ])
  end
end
