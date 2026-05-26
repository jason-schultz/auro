defmodule OpusWeb.RegimeControllerTest do
  use OpusWeb.ConnCase, async: false

  import Ecto.Query

  alias Opus.Repo
  alias Opus.Trading.LiveStrategy
  alias Opus.Trading.RegimeDetector

  setup do
    start_supervised!(RegimeDetector)

    from(s in LiveStrategy, where: s.instrument in ["EUR_USD", "XAU_USD"])
    |> Repo.delete_all()

    now = DateTime.utc_now()

    Repo.insert_all(LiveStrategy, [
      %{
        id: "11111111-2222-3333-4444-555555555551",
        strategy_type: "trend_following",
        instrument: "EUR_USD",
        granularity: "H1",
        parameters: %{},
        enabled: true,
        max_position_size: "1000",
        created_at: now,
        updated_at: now
      },
      %{
        id: "11111111-2222-3333-4444-555555555552",
        strategy_type: "trend_following",
        instrument: "XAU_USD",
        granularity: "H1",
        parameters: %{},
        enabled: false,
        max_position_size: "1000",
        created_at: now,
        updated_at: now
      }
    ])

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
      from(s in LiveStrategy, where: s.instrument in ["EUR_USD", "XAU_USD"])
      |> Repo.delete_all()
    end)

    :ok
  end

  test "returns heatmap rows for enabled instruments only", %{conn: conn} do
    conn = get(conn, "/regimes/heatmap")

    assert %{
             "count" => 1,
             "instruments" => ["EUR_USD"],
             "granularities" => ["H4", "H1"],
             "rows" => [row]
           } = json_response(conn, 200)

    assert row["instrument"] == "EUR_USD"
    assert length(row["cells"]) == 2

    h1 = Enum.find(row["cells"], &(&1["granularity"] == "H1"))
    h4 = Enum.find(row["cells"], &(&1["granularity"] == "H4"))

    assert h1["regime"] == "trending"
    assert is_number(h1["adx"])
    assert h4["regime"] == "unknown"
  end
end
