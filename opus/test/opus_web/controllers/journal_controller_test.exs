defmodule OpusWeb.JournalControllerTest do
  use OpusWeb.ConnCase, async: false

  import Ecto.Query

  alias Opus.Repo
  alias Opus.Trading.LiveStrategy
  alias Opus.Trading.LiveTrade

  setup do
    from(t in LiveTrade) |> Repo.delete_all()
    from(s in LiveStrategy) |> Repo.delete_all()

    now = DateTime.utc_now()

    Repo.insert_all(LiveStrategy, [
      %{
        id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        strategy_type: "trend_following",
        instrument: "XAU_USD",
        granularity: "H1",
        parameters: %{},
        enabled: true,
        max_position_size: "1000",
        created_at: now,
        updated_at: now
      },
      %{
        id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        strategy_type: "mean_reversion",
        instrument: "XAU_USD",
        granularity: "H1",
        parameters: %{},
        enabled: true,
        max_position_size: "1000",
        created_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all(LiveTrade, [
      %{
        live_strategy_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        instrument: "XAU_USD",
        pnl: 100.0,
        mfe_pct: 2.0,
        mae_pct: 0.5,
        regime_at_entry: "trending H4:35.0",
        status: "closed",
        exit_time: DateTime.add(now, -2 * 3_600, :second),
        created_at: now,
        updated_at: now
      },
      %{
        live_strategy_id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        instrument: "XAU_USD",
        pnl: -50.0,
        mfe_pct: 1.2,
        mae_pct: 0.8,
        regime_at_entry: "choppy H1:14.0",
        status: "closed",
        exit_time: DateTime.add(now, -90 * 60, :second),
        created_at: now,
        updated_at: now
      },
      %{
        live_strategy_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        instrument: "WTICO_USD",
        pnl: 0.0,
        mfe_pct: 0.4,
        mae_pct: 0.3,
        regime_at_entry: nil,
        status: "closed",
        exit_time: DateTime.add(now, -3_600, :second),
        created_at: now,
        updated_at: now
      }
    ])

    :ok
  end

  test "returns journal KPI payload shape", %{conn: conn} do
    conn = get(conn, "/journal/kpis")

    body = json_response(conn, 200)
    assert body["trade_count"] == 3
    assert body["win_count"] == 1
    assert body["loss_count"] == 1
    assert is_list(body["by_instrument"])
    assert is_list(body["by_strategy_type"])
    assert is_list(body["by_regime_at_entry"])
  end
end
