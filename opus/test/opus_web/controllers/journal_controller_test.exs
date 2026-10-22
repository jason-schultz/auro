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
        created_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all(LiveTrade, [
      %{
        id: "cccccccc-cccc-cccc-cccc-ccccccccccc1",
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
        id: "cccccccc-cccc-cccc-cccc-ccccccccccc2",
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
        id: "cccccccc-cccc-cccc-cccc-ccccccccccc3",
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
    conn = get(conn, "/api/journal/kpis")

    body = json_response(conn, 200)
    assert body["trade_count"] == 3
    assert body["win_count"] == 1
    assert body["loss_count"] == 1
    assert is_list(body["by_instrument"])
    assert is_list(body["by_strategy_type"])
    assert is_list(body["by_regime_at_entry"])
  end
end

defmodule OpusWeb.JournalControllerExecutionQualityTest do
  use OpusWeb.ConnCase, async: false

  import Ecto.Query

  alias Opus.Repo
  alias Opus.Trading.LiveStrategy
  alias Opus.Trading.LiveTrade

  @strategy "dddddddd-dddd-dddd-dddd-dddddddddddd"

  setup do
    from(t in LiveTrade) |> Repo.delete_all()
    from(s in LiveStrategy) |> Repo.delete_all()
    now = DateTime.utc_now()

    Repo.insert_all(LiveStrategy, [
      %{
        id: @strategy,
        strategy_type: "composite",
        instrument: "NAS100_USD",
        granularity: "M5",
        parameters: %{},
        enabled: true,
        created_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all(LiveTrade, [
      # Long: paid 1 point over the expected ask, sold 2 under the expected bid.
      %{
        id: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee1",
        live_strategy_id: @strategy,
        instrument: "NAS100_USD",
        direction: "Long",
        status: "closed",
        entry_time: DateTime.add(now, -3_600, :second),
        exit_time: DateTime.add(now, -1_800, :second),
        signal_price: 20_000.0,
        entry_price: 20_001.0,
        expected_entry_price: 20_000.0,
        entry_spread: 2.0,
        exit_price: 19_998.0,
        expected_exit_price: 20_000.0,
        exit_spread: 2.0,
        created_at: now,
        updated_at: now
      },
      # Stop-loss exit: no expected exit price, so only the entry is measured.
      %{
        id: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee2",
        live_strategy_id: @strategy,
        instrument: "NAS100_USD",
        direction: "Short",
        status: "closed",
        entry_time: DateTime.add(now, -7_200, :second),
        exit_time: DateTime.add(now, -5_400, :second),
        signal_price: 20_000.0,
        entry_price: 19_999.0,
        expected_entry_price: 20_000.0,
        entry_spread: 4.0,
        exit_price: 20_100.0,
        created_at: now,
        updated_at: now
      },
      # Pre-feature trade with no expected prices: excluded entirely.
      %{
        id: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee3",
        live_strategy_id: @strategy,
        instrument: "NAS100_USD",
        direction: "Long",
        status: "closed",
        entry_time: DateTime.add(now, -10_800, :second),
        entry_price: 1.0,
        created_at: now,
        updated_at: now
      }
    ])

    :ok
  end

  test "reports per-strategy slippage against the backtest's assumed fills", %{conn: conn} do
    conn = get(conn, "/api/journal/execution-quality")
    assert %{"strategies" => [row]} = json_response(conn, 200)

    assert row["live_strategy_id"] == @strategy
    assert row["instrument"] == "NAS100_USD"
    assert row["trades"] == 2
    assert row["entries_measured"] == 2
    assert row["exits_measured"] == 1
    # (+0.5 bp long, +0.5 bp short) / 2
    assert_in_delta row["mean_entry_slippage_bp"], 0.5, 1.0e-9
    assert_in_delta row["mean_exit_slippage_bp"], 1.0, 1.0e-9
    assert_in_delta row["mean_spread_bp"], 1.5, 1.0e-9
    assert_in_delta row["mean_round_trip_excess_bp"], 1.5, 1.0e-9
  end

  test "rejects a malformed window", %{conn: conn} do
    conn = get(conn, "/api/journal/execution-quality", %{from: "yesterday"})
    assert %{"error" => _} = json_response(conn, 400)
  end
end
