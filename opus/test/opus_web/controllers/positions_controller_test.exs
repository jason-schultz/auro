defmodule OpusWeb.PositionsControllerTest do
  use OpusWeb.ConnCase, async: false

  alias Opus.Repo

  @trade_id "T-SPARK-TEST-1"
  @instrument "EUR_USD"

  setup do
    {:ok, eur} = Opus.Instruments.add(@instrument, "fx_major")

    Repo.query!(
      """
      INSERT INTO live_trades (id, oanda_trade_id, instrument, instrument_id, direction, units, entry_time, status)
      VALUES ('00000000-0000-0000-0000-00000000aa01', $1, $2, $3, 'long', '1000', NOW() - interval '5 minutes', 'open')
      """,
      [@trade_id, @instrument, eur.id]
    )

    Repo.query!(
      """
      INSERT INTO candles (instrument_id, instrument, granularity, timestamp, open, high, low, close, volume, complete)
      VALUES
      ($1, $2, 'M1', NOW() - interval '4 minutes', 1.1000, 1.1010, 1.0990, 1.1005, 10, true),
      ($1, $2, 'M1', NOW() - interval '3 minutes', 1.1005, 1.1015, 1.1000, 1.1010, 12, true),
      ($1, $2, 'M1', NOW() - interval '2 minutes', 1.1010, 1.1020, 1.1008, 1.1018, 14, true)
      """,
      [eur.id, @instrument]
    )

    :ok
  end

  test "returns sparkline candles for a live trade", %{conn: conn} do
    conn = get(conn, "/api/positions/#{@trade_id}/sparkline", %{bars: "2"})

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
    conn = get(conn, "/api/positions/UNKNOWN-TRADE/sparkline")

    assert %{"error" => "trade not found"} = json_response(conn, 404)
  end
end
