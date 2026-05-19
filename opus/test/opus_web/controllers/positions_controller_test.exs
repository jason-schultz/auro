defmodule OpusWeb.PositionsControllerTest do
  use OpusWeb.ConnCase, async: false

  alias Opus.Repo

  @trade_id "T-SPARK-TEST-1"
  @instrument "EUR_USD"

  setup do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS live_trades (
      id UUID PRIMARY KEY,
      oanda_trade_id VARCHAR(50),
      instrument VARCHAR(20) NOT NULL,
      direction VARCHAR(10) NOT NULL,
      units VARCHAR(20) NOT NULL,
      entry_time TIMESTAMPTZ NOT NULL,
      status VARCHAR(20) NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS candles (
      id UUID PRIMARY KEY,
      instrument VARCHAR(20) NOT NULL,
      granularity VARCHAR(5) NOT NULL,
      timestamp TIMESTAMPTZ NOT NULL,
      open DOUBLE PRECISION NOT NULL,
      high DOUBLE PRECISION NOT NULL,
      low DOUBLE PRECISION NOT NULL,
      close DOUBLE PRECISION NOT NULL,
      volume INTEGER NOT NULL,
      complete BOOLEAN NOT NULL
    )
    """)

    Repo.query!("DELETE FROM candles WHERE instrument = $1", [@instrument])
    Repo.query!("DELETE FROM live_trades WHERE oanda_trade_id = $1", [@trade_id])

    Repo.query!(
      """
      INSERT INTO live_trades (id, oanda_trade_id, instrument, direction, units, entry_time, status)
      VALUES ('00000000-0000-0000-0000-00000000aa01', $1, $2, 'long', '1000', NOW() - interval '5 minutes', 'open')
      """,
      [@trade_id, @instrument]
    )

    Repo.query!(
      """
      INSERT INTO candles (id, instrument, granularity, timestamp, open, high, low, close, volume, complete)
      VALUES
      ('00000000-0000-0000-0000-00000000bb01', $1, 'M1', NOW() - interval '4 minutes', 1.1000, 1.1010, 1.0990, 1.1005, 10, true),
      ('00000000-0000-0000-0000-00000000bb02', $1, 'M1', NOW() - interval '3 minutes', 1.1005, 1.1015, 1.1000, 1.1010, 12, true),
      ('00000000-0000-0000-0000-00000000bb03', $1, 'M1', NOW() - interval '2 minutes', 1.1010, 1.1020, 1.1008, 1.1018, 14, true)
      """,
      [@instrument]
    )

    :ok
  end

  test "returns sparkline candles for a live trade", %{conn: conn} do
    conn = get(conn, "/positions/#{@trade_id}/sparkline", %{bars: "2"})

    assert %{
             "trade_id" => @trade_id,
             "instrument" => @instrument,
             "bars" => 2,
             "candles" => candles
           } =
             json_response(conn, 200)

    assert length(candles) == 2
    assert Enum.all?(candles, &Map.has_key?(&1, "close"))
  end

  test "returns 404 when trade id is unknown", %{conn: conn} do
    conn = get(conn, "/positions/UNKNOWN-TRADE/sparkline")

    assert %{"error" => "trade not found"} = json_response(conn, 404)
  end
end
