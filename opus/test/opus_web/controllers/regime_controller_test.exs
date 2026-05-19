defmodule OpusWeb.RegimeControllerTest do
  use OpusWeb.ConnCase, async: false

  alias Opus.Repo
  alias Opus.Trading.RegimeDetector

  setup do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS live_strategies (
      id UUID PRIMARY KEY,
      strategy_type VARCHAR(50) NOT NULL,
      instrument VARCHAR(20) NOT NULL,
      granularity VARCHAR(5) NOT NULL,
      parameters JSONB NOT NULL,
      enabled BOOLEAN NOT NULL DEFAULT false,
      max_position_size VARCHAR(20) NOT NULL DEFAULT '1000'
    )
    """)

    Repo.query!("DELETE FROM live_strategies WHERE instrument IN ('EUR_USD', 'XAU_USD')")

    Repo.query!("""
    INSERT INTO live_strategies (id, strategy_type, instrument, granularity, parameters, enabled, max_position_size)
    VALUES
      ('11111111-2222-3333-4444-555555555551', 'trend_following', 'EUR_USD', 'H1', '{}'::jsonb, true, '1000'),
      ('11111111-2222-3333-4444-555555555552', 'trend_following', 'XAU_USD', 'H1', '{}'::jsonb, false, '1000')
    """)

    previous_state = :sys.get_state(RegimeDetector)

    :sys.replace_state(RegimeDetector, fn state ->
      %{
        state
        | last_run: DateTime.utc_now(),
          regimes: %{
            {"EUR_USD", "H1"} => %{
              regime: :trending,
              adx: 33.5,
              bandwidth_pct: 1.2,
              last_close_time: DateTime.utc_now()
            }
          }
      }
    end)

    on_exit(fn ->
      :sys.replace_state(RegimeDetector, fn _ -> previous_state end)
      Repo.query!("DELETE FROM live_strategies WHERE instrument IN ('EUR_USD', 'XAU_USD')")
    end)

    :ok
  end

  test "returns heatmap rows for enabled instruments only", %{conn: conn} do
    conn = get(conn, "/regimes/heatmap")

    assert %{
             "count" => 1,
             "instruments" => ["EUR_USD"],
             "granularities" => ["D", "H4", "H1", "M15"],
             "rows" => [row]
           } = json_response(conn, 200)

    assert row["instrument"] == "EUR_USD"
    assert length(row["cells"]) == 4

    h1 = Enum.find(row["cells"], &(&1["granularity"] == "H1"))
    d = Enum.find(row["cells"], &(&1["granularity"] == "D"))

    assert h1["regime"] == "trending"
    assert is_number(h1["adx"])
    assert d["regime"] == "unknown"
  end
end
