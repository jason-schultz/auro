defmodule Opus.Options.Paper.StructuresTest do
  use ExUnit.Case, async: true

  alias Opus.Options.Paper.Structures

  @as_of ~D[2026-10-23]
  @dte 38

  defp row(kind, strike, delta, bid, ask, dte \\ @dte) do
    %{
      contract_id: System.unique_integer([:positive]),
      kind: kind,
      strike: strike,
      dte: dte,
      expiration: Date.add(@as_of, dte),
      delta: delta,
      bid: bid,
      ask: ask
    }
  end

  defp snapshot(spot, chain, quotes \\ %{}),
    do: %{as_of: @as_of, spot: spot, quotes: quotes, chain: chain, expiry_spots: %{}}

  defp chain do
    [
      row("put", 560.0, -0.05, 1.00, 1.04),
      row("put", 580.0, -0.10, 2.00, 2.06),
      row("put", 600.0, -0.16, 3.00, 3.10),
      row("put", 610.0, -0.25, 5.00, 5.10),
      row("call", 640.0, 0.16, 3.00, 3.10),
      row("call", 660.0, 0.05, 1.00, 1.04),
      # A closer delta on another expiry is ignored for the wing.
      row("put", 590.0, -0.10, 2.40, 2.46, 44)
    ]
  end

  describe "entry" do
    test "a put spread sells −0.25 and buys −0.10 below it on the same expiry" do
      [long, short] = Structures.entry("put_spread", chain())
      assert {short.side, short.strike, short.open_price} == {"short", 610.0, 5.00}
      assert {long.side, long.strike, long.open_price} == {"long", 580.0, 2.06}
      # Width 30, credit 2.94: reserves 3,000 − 294.
      assert_in_delta Structures.collateral([long, short]), 2_706.0, 1.0e-9
    end

    test "an iron condor sells the 16-deltas and buys the 5-delta wings" do
      legs = Structures.entry("iron_condor", chain())

      assert Enum.map(legs, &{&1.side, &1.kind, &1.strike}) == [
               {"long", "put", 560.0},
               {"short", "put", 600.0},
               {"short", "call", 640.0},
               {"long", "call", 660.0}
             ]
    end

    test "no structure without a credit or a wing" do
      assert Structures.entry("put_spread", [row("put", 610.0, -0.25, 5.0, 5.1)]) == nil
      dear_wing = [row("put", 610.0, -0.25, 1.0, 1.04), row("put", 580.0, -0.10, 2.0, 2.04)]
      assert Structures.entry("put_spread", dear_wing) == nil
    end
  end

  describe "management" do
    setup do
      [long, short] = Structures.entry("put_spread", chain())
      trade = %{id: 1, legs: [%{long | contract_id: 1}, %{short | contract_id: 2}]}
      %{trade: trade}
    end

    test "closes once it costs half the credit or less", %{trade: trade} do
      # Credit 2.94; buying back costs 2.00 − 0.55 = 1.45.
      quotes = %{2 => %{bid: 1.95, ask: 2.00}, 1 => %{bid: 0.55, ask: 0.57}}
      assert {:close, ^trade, fills} = Structures.manage(trade, quotes, snapshot(640.0, []))
      assert Enum.map(fills, &elem(&1, 1)) == [0.55, 2.00]

      quotes = %{2 => %{bid: 2.95, ask: 3.0}, 1 => %{bid: 0.55, ask: 0.57}}
      assert {:hold, ^trade} = Structures.manage(trade, quotes, snapshot(640.0, []))
    end

    test "closes at 21 days to expiry whatever its value", %{trade: trade} do
      late = %{snapshot(600.0, []) | as_of: Date.add(@as_of, @dte - 21)}
      quotes = %{2 => %{bid: 12.0, ask: 12.4}, 1 => %{bid: 3.0, ask: 3.1}}
      assert {:close, ^trade, _fills} = Structures.manage(trade, quotes, late)

      refute match?(
               {:close, _, _},
               Structures.manage(trade, quotes, %{late | as_of: Date.add(late.as_of, -1)})
             )
    end

    test "holds when any leg can't be filled", %{trade: trade} do
      late = %{snapshot(600.0, []) | as_of: Date.add(@as_of, @dte - 21)}
      assert {:hold, ^trade} = Structures.manage(trade, %{2 => %{bid: 1.0, ask: 1.02}}, late)
    end

    test "settles at intrinsic once expired", %{trade: trade} do
      expired = %{snapshot(590.0, []) | as_of: Date.add(@as_of, @dte), expiry_spots: %{}}
      assert {:settle, ^trade, 590.0} = Structures.manage(trade, %{}, expired)
    end
  end

  describe "plan" do
    test "opens only when its maximum loss fits the cash" do
      snap = snapshot(620.0, chain())

      assert [{:open, "put_spread", _legs}] =
               Structures.plan("put_spread", nil, snap, 3_000.0, 0.1)

      assert [] = Structures.plan("put_spread", nil, snap, 2_000.0, 0.1)
    end

    test "a closed trade's collateral pays for tonight's new one" do
      [long, short] = Structures.entry("put_spread", chain())
      trade = %{id: 1, legs: [%{long | contract_id: 1}, %{short | contract_id: 2}]}
      quotes = %{2 => %{bid: 1.0, ask: 1.02}, 1 => %{bid: 0.2, ask: 0.21}}
      snap = snapshot(640.0, chain(), quotes)

      # 100 free plus the 2,706 the closed spread held, less the 82.20 to
      # close it, covers the new spread's 2,706.
      assert [{:close, ^trade, _}, {:open, "put_spread", _}] =
               Structures.plan("put_spread", trade, snap, 100.0, 0.1)
    end
  end
end
