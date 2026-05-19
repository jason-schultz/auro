defmodule OpusWeb.AccountControllerTest do
  use OpusWeb.ConnCase, async: false

  alias Opus.Repo

  setup do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS account_snapshots (
      id UUID PRIMARY KEY,
      timestamp TIMESTAMPTZ NOT NULL,
      nav DOUBLE PRECISION NOT NULL,
      balance DOUBLE PRECISION NOT NULL,
      unrealized_pl DOUBLE PRECISION NOT NULL,
      margin_used DOUBLE PRECISION NOT NULL,
      margin_available DOUBLE PRECISION NOT NULL,
      currency VARCHAR(10) NOT NULL,
      open_position_count INT NOT NULL DEFAULT 0,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    Repo.query!("DELETE FROM account_snapshots")

    Repo.query!("""
    INSERT INTO account_snapshots (id, timestamp, nav, balance, unrealized_pl, margin_used, margin_available, currency, open_position_count)
    VALUES
      ('11111111-1111-1111-1111-111111111111', NOW() - interval '20 minutes', 100000, 99900, 100, 1200, 98800, 'CAD', 2),
      ('22222222-2222-2222-2222-222222222222', NOW() - interval '10 minutes', 100150, 100000, 150, 1250, 98750, 'CAD', 2)
    """)

    :ok
  end

  test "returns equity curve points", %{conn: conn} do
    conn = get(conn, "/account/equity-curve", %{resolution: "15m"})

    assert %{"points" => points, "resolution" => "15m"} = json_response(conn, 200)
    assert length(points) >= 1
    assert Enum.all?(points, &Map.has_key?(&1, "nav"))
  end
end
