defmodule Opus.MarketData.SpreadWorkerTest do
  use Opus.DataCase, async: false

  alias Opus.Instruments
  alias Opus.MarketData.SpreadWorker

  @now ~U[2026-11-02 17:00:00Z]

  test "samples come from two-sided, unhalted quotes of known markets, in basis points" do
    quotes = [
      %{"requested" => "SPY", "bid_price" => 599.98, "ask_price" => 600.02, "is_halted" => false},
      # One-sided, halted, crossed, or not one of ours: skipped.
      %{"requested" => "IWM", "bid_price" => nil, "ask_price" => 220.1, "is_halted" => false},
      %{"requested" => "QQQ", "bid_price" => 500.0, "ask_price" => 500.1, "is_halted" => true},
      %{"requested" => "DIA", "bid_price" => 430.2, "ask_price" => 430.1, "is_halted" => false},
      %{"requested" => "ZZZ", "bid_price" => 1.0, "ask_price" => 1.1, "is_halted" => false}
    ]

    assert [row] =
             SpreadWorker.rows(quotes, %{"SPY" => 1, "IWM" => 2, "QQQ" => 3, "DIA" => 4}, @now)

    assert row.instrument_id == 1
    assert_in_delta row.spread_bps, 0.6667, 0.001
  end

  test "it samples mid-session on trading days only" do
    # 11:00 and 15:45 New York on a Monday; 9:45, 15:46 and a Saturday not.
    assert SpreadWorker.sampling?(~U[2026-11-02 16:00:00Z])
    assert SpreadWorker.sampling?(~U[2026-11-02 20:45:00.500Z])
    refute SpreadWorker.sampling?(~U[2026-11-02 14:45:00Z])
    refute SpreadWorker.sampling?(~U[2026-11-02 20:46:00Z])
    refute SpreadWorker.sampling?(~U[2026-10-31 16:00:00Z])
  end

  test "settling sets a market's spread to its median once it has enough samples" do
    {:ok, spy} = Instruments.add("SPY", "etf")
    {:ok, iwm} = Instruments.add("IWM", "etf")

    sample = fn id, bps, at ->
      %{instrument_id: id, captured_at: at, bid: 1.0, ask: 1.0, spread_bps: bps}
    end

    recent = DateTime.add(@now, -86_400) |> DateTime.truncate(:second)
    old = DateTime.add(@now, -90 * 86_400) |> DateTime.truncate(:second)

    Repo.insert_all(
      "spread_samples",
      Enum.map(1..41, &sample.(spy.id, &1 / 10, recent)) ++
        Enum.map(1..10, fn _ -> sample.(iwm.id, 5.0, recent) end) ++ [sample.(spy.id, 99.0, old)]
    )

    assert {1, nil} = SpreadWorker.settle(@now)
    assert_in_delta Repo.reload(spy).spread_bps, 2.1, 1.0e-9
    # Too few samples: still the broker's default.
    assert Repo.reload(iwm).spread_bps == nil
    # Samples past the keep window are dropped.
    assert Repo.aggregate("spread_samples", :count) == 51
  end
end
