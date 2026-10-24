defmodule Opus.Options.ScanTest do
  use Opus.DataCase, async: false

  alias Opus.Options.Scan

  @etf %{symbol: "IWM", instrument_id: 1, asset_class: "etf"}
  @single %{symbol: "NVDA", instrument_id: 2, asset_class: "equity"}
  @today ~D[2026-10-24]

  defp candidate(kind, strike, dte, attrs \\ %{}) do
    Map.merge(
      %{
        contract_id: :erlang.phash2({kind, strike, dte}),
        symbol: "IWM",
        kind: kind,
        strike: strike,
        expiration: Date.add(@today, dte),
        dte: dte,
        bid: 2.0,
        ask: 2.2,
        volatility: 20.0,
        delta: if(kind == "call", do: 0.4, else: -0.4),
        open_interest: 800,
        spot: 230.0
      },
      attrs
    )
  end

  # A stand-in for the engine: breakeven at strike plus premium, a 7%
  # expected move, and a chance of profit that falls with the strike.
  defp model(%{kind: "call", strike: strike, ask: ask, spot: spot}),
    do: %{
      "breakeven" => strike + ask,
      "expected_move" => spot * 0.07,
      "probability_profit" => max(0.0, 0.6 - (strike - spot) / spot)
    }

  defp model(%{kind: "put", strike: strike, ask: ask, spot: spot}),
    do: %{
      "breakeven" => strike - ask,
      "expected_move" => spot * 0.07,
      "probability_profit" => 0.4
    }

  test "a dip-buy setup lists the calls ranked, marks lottery deltas, and never hides them" do
    indicators = %{"rsi" => 6.2, "ma_deviation_pct" => 3.1, "realized_vol_pct" => 24.0}

    candidates = [
      candidate("call", 230.0, 45),
      candidate("call", 240.0, 45),
      candidate("call", 260.0, 45, %{delta: 0.08, ask: 0.3, bid: 0.25}),
      candidate("call", 230.0, 45, %{bid: 0.0, ask: 0.0, strike: 300.0}),
      candidate("put", 230.0, 45)
    ]

    ideas = Scan.ideas_for(@etf, indicators, candidates, @today, &model/1)
    dip = Enum.filter(ideas, &(&1.list == "dip_buy"))

    assert Enum.map(dip, & &1.strike) == [230.0, 240.0, 260.0]
    assert [%{lottery: false}, %{lottery: false}, %{lottery: true}] = dip
    assert Enum.all?(dip, &(&1.kind == "call" and &1.setup =~ "RSI(2) 6.2 under 10"))
    assert hd(dip).breakeven_move_pct > 0 and hd(dip).expected_move_pct == 0.07
    assert hd(dip).iv_rv == 20.0 / 24.0

    assert dip
           |> Enum.map(& &1.score)
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [a, b] -> a >= b end)

    # The cheap-vol pair comes along too: one call and one put at the money.
    cheap = Enum.filter(ideas, &(&1.list == "cheap_vol"))
    assert Enum.map(cheap, &{&1.kind, &1.strike}) == [{"call", 230.0}, {"put", 230.0}]
    assert Enum.all?(cheap, &(&1.setup == "implied 20.0% vs realized 24.0%"))
  end

  test "no setup means no dip-buy ideas; single names never get them; cheap-vol picks the expiry nearest 45 days" do
    calm = %{"rsi" => 55.0, "ma_deviation_pct" => 1.0, "realized_vol_pct" => 24.0}
    oversold = %{"rsi" => 4.0, "ma_deviation_pct" => 1.0, "realized_vol_pct" => 24.0}
    below_average = %{"rsi" => 4.0, "ma_deviation_pct" => -2.0, "realized_vol_pct" => 24.0}

    candidates = [
      candidate("call", 230.0, 32),
      candidate("put", 230.0, 32),
      candidate("call", 231.0, 46)
    ]

    refute Scan.dip_buy_setup?(@etf, calm)
    refute Scan.dip_buy_setup?(@etf, below_average)
    refute Scan.dip_buy_setup?(@single, oversold)
    assert Scan.dip_buy_setup?(@etf, oversold)

    ideas = Scan.ideas_for(@single, oversold, candidates, @today, &model/1)
    assert Enum.map(ideas, & &1.list) == ["cheap_vol"]
    assert [%{dte: 46, strike: 231.0, kind: "call"}] = ideas
  end

  test "ideas_for survives missing volatility and a model that declines" do
    indicators = %{"rsi" => 4.0, "ma_deviation_pct" => 1.0, "realized_vol_pct" => nil}
    candidates = [candidate("call", 230.0, 45, %{volatility: nil})]

    assert [dip, cheap] = Scan.ideas_for(@etf, indicators, candidates, @today, &model/1)
    assert dip.iv_rv == nil and dip.rv_pct == nil
    assert cheap.setup == "no volatility on the quote"

    assert Scan.ideas_for(@etf, indicators, candidates, @today, fn _ -> nil end) == []
  end

  # config/test.exs points the Auro client at a closed port: with no engine
  # there are no indicators, so a run records nothing rather than failing.
  test "run/1 without the engine records nothing" do
    assert {:ok, 0} = Scan.run(@today)
  end
end
