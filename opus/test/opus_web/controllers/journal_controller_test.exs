defmodule OpusWeb.JournalControllerTest do
  use OpusWeb.ConnCase, async: false

  alias Opus.Repo

  setup do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS live_strategies (
      id UUID PRIMARY KEY,
      strategy_type VARCHAR(50) NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS live_trades (
      id UUID PRIMARY KEY,
      live_strategy_id UUID,
      instrument VARCHAR(20) NOT NULL,
      pnl DOUBLE PRECISION,
      mfe_pct DOUBLE PRECISION,
      mae_pct DOUBLE PRECISION,
      regime_at_entry VARCHAR(120),
      status VARCHAR(20) NOT NULL,
      exit_time TIMESTAMPTZ
    )
    """)

    Repo.query!("DELETE FROM live_trades")
    Repo.query!("DELETE FROM live_strategies")

    Repo.query!("""
    INSERT INTO live_strategies (id, strategy_type)
    VALUES
      ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'trend_following'),
      ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'mean_reversion')
    """)

    Repo.query!("""
    INSERT INTO live_trades (id, live_strategy_id, instrument, pnl, mfe_pct, mae_pct, regime_at_entry, status, exit_time)
    VALUES
      ('00000000-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'XAU_USD', 100, 2.0, 0.5, 'trending H4:35.0', 'closed', NOW() - interval '2 hours'),
      ('00000000-0000-0000-0000-000000000002', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'XAU_USD', -50, 1.2, 0.8, 'choppy H1:14.0', 'closed', NOW() - interval '90 minutes'),
      ('00000000-0000-0000-0000-000000000003', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'WTICO_USD', 0, 0.4, 0.3, NULL, 'closed', NOW() - interval '1 hour')
    """)

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
