defmodule Opus.Options.Paper.LongOptionsTest do
  use ExUnit.Case, async: true

  alias Opus.Options.Paper.LongOptions

  @as_of ~D[2026-10-23]

  defp row(kind, strike, delta, bid, ask, dte \\ 38) do
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

  defp snapshot(spot, chain, quotes),
    do: %{as_of: @as_of, spot: spot, quotes: quotes, chain: chain, expiry_spots: %{}}

  defp trade(open_price, dte \\ 38, quantity \\ 1) do
    %{
      id: 1,
      legs: [
        %{
          contract_id: 7,
          kind: "call",
          side: "long",
          strike: 650.0,
          expiration: Date.add(@as_of, dte),
          open_price: open_price,
          quantity: quantity
        }
      ]
    }
  end

  describe "ideas exits" do
    test "sell at double, at half, or at 21 days" do
      t = trade(4.0)

      at = fn bid ->
        LongOptions.manage(
          "ideas",
          t,
          %{7 => %{bid: bid, ask: bid * 1.02}},
          snapshot(650.0, [], %{})
        )
      end

      assert {:close, ^t, [{_, 8.0}]} = at.(8.0)
      assert {:close, ^t, [{_, 2.0}]} = at.(2.0)
      assert {:hold, ^t} = at.(5.0)

      t = trade(4.0, 21)

      assert {:close, ^t, _} =
               LongOptions.manage(
                 "ideas",
                 t,
                 %{7 => %{bid: 5.0, ask: 5.1}},
                 snapshot(650.0, [], %{})
               )
    end

    test "a crash put has no take-profit, only the 21-day roll" do
      t = trade(4.0)

      assert {:hold, ^t} =
               LongOptions.manage(
                 "crash_puts",
                 t,
                 %{7 => %{bid: 9.0, ask: 9.1}},
                 snapshot(650.0, [], %{})
               )
    end

    test "expired legs settle against the expiry-day close" do
      t = trade(4.0, -1)
      [%{expiration: expiration}] = t.legs
      settled = %{snapshot(700.0, [], %{}) | expiry_spots: %{expiration => 660.0}}

      assert {:hold, ^t} = LongOptions.manage("ideas", t, %{}, snapshot(700.0, [], %{}))
      assert {:settle, ^t, 660.0} = LongOptions.manage("ideas", t, %{}, settled)
    end
  end

  describe "ideas entries" do
    defp idea(contract_id), do: %{list: "dip_buy", kind: "call", contract_id: contract_id}

    setup do
      cheap = row("call", 650.0, 0.4, 5.0, 5.1)
      dear = row("call", 600.0, 0.8, 25.0, 25.4)
      %{cheap: cheap, dear: dear, quotes: Map.new([cheap, dear], &{&1.contract_id, &1})}
    end

    test "buys new ideas under the premium cap", %{cheap: cheap, dear: dear, quotes: quotes} do
      snap = snapshot(650.0, [], quotes)
      ideas = [idea(cheap.contract_id), idea(dear.contract_id)]

      assert [{:open, "long_call", [%{open_price: 5.1, side: "long"}]}] =
               LongOptions.plan_ideas("ideas", [], ideas, snap, 100_000.0, 0.1, 0, MapSet.new())
    end

    test "never buys a contract twice and keeps at most 5 open", %{cheap: cheap, quotes: quotes} do
      snap = snapshot(650.0, [], quotes)
      ideas = [idea(cheap.contract_id)]
      held = MapSet.new([cheap.contract_id])
      assert [] = LongOptions.plan_ideas("ideas", [], ideas, snap, 100_000.0, 0.1, 0, held)

      assert [] =
               LongOptions.plan_ideas("ideas", [], ideas, snap, 100_000.0, 0.1, 5, MapSet.new())
    end

    test "a better idea on an underlying still to run keeps its place in the cap",
         %{cheap: cheap, quotes: quotes} do
      snap = snapshot(650.0, [], quotes) |> Map.put(:instrument_id, 1)
      mine = Map.put(idea(cheap.contract_id), :underlying_instrument_id, 1)

      later =
        Map.merge(idea(-1), %{underlying_instrument_id: 2, bid: 3.0, ask: 3.05})

      # Four open elsewhere: the one slot left goes to the better idea later on.
      assert [] =
               LongOptions.plan_ideas(
                 "ideas",
                 [],
                 [later, mine],
                 snap,
                 1.0e5,
                 0.1,
                 4,
                 MapSet.new()
               )

      # A later idea that couldn't be filled holds nothing.
      unfillable = %{later | bid: 0.0}

      assert [{:open, "long_call", _}] =
               LongOptions.plan_ideas(
                 "ideas",
                 [],
                 [unfillable, mine],
                 snap,
                 1.0e5,
                 0.1,
                 4,
                 MapSet.new()
               )

      # With room for both, this underlying's idea is bought.
      assert [{:open, "long_call", _}] =
               LongOptions.plan_ideas(
                 "ideas",
                 [],
                 [later, mine],
                 snap,
                 1.0e5,
                 0.1,
                 3,
                 MapSet.new()
               )
    end

    test "needs the cash", %{cheap: cheap, quotes: quotes} do
      snap = snapshot(650.0, [], quotes)

      assert [] =
               LongOptions.plan_ideas(
                 "ideas",
                 [],
                 [idea(cheap.contract_id)],
                 snap,
                 100.0,
                 0.1,
                 0,
                 MapSet.new()
               )
    end
  end

  describe "crash puts" do
    test "buys the −0.10 put, and rolls it at 21 days" do
      chain = [row("put", 580.0, -0.10, 2.0, 2.06), row("put", 600.0, -0.20, 4.0, 4.1)]
      snap = snapshot(640.0, chain, %{})

      assert [{:open, "long_put", [%{strike: 580.0}]}] =
               LongOptions.plan_crash_puts("crash_puts", [], snap, 10_000.0, 0.1)

      old = %{trade(3.0, 21) | legs: [%{hd(trade(3.0, 21).legs) | kind: "put", strike: 570.0}]}
      snap = %{snap | quotes: %{7 => %{bid: 1.0, ask: 1.02}}}

      assert [{:close, ^old, _}, {:open, "long_put", _}] =
               LongOptions.plan_crash_puts("crash_puts", [old], snap, 1_000.0, 0.1)
    end
  end

  describe "half at double" do
    defp at(book, t, bid),
      do:
        LongOptions.manage(
          book,
          t,
          %{7 => %{bid: bid, ask: bid * 1.02}},
          snapshot(650.0, [], %{})
        )

    test "buys two contracts" do
      assert LongOptions.contracts("ideas_half") == 2
      assert LongOptions.contracts("crash_puts_half") == 2
      assert LongOptions.contracts("ideas") == 1

      chain = [row("put", 580.0, -0.10, 2.0, 2.06)]

      assert [{:open, "long_put", [%{quantity: 2}]}] =
               LongOptions.plan_crash_puts(
                 "crash_puts_half",
                 [],
                 snapshot(640.0, chain, %{}),
                 10_000.0,
                 0.1
               )
    end

    test "sells half at double; before that ideas still sell all at half, crash puts hold" do
      t = trade(4.0, 38, 2)

      for book <- ~w(ideas_half crash_puts_half) do
        assert {:sell_half, ^t, %{quantity: 2}, 8.0} = at(book, t, 8.0)
        assert {:hold, ^t} = at(book, t, 5.0)
      end

      assert {:close, ^t, [{_, 2.0}]} = at("ideas_half", t, 2.0)
      assert {:hold, ^t} = at("crash_puts_half", t, 2.0)
    end

    test "the rest rides until it falls back to the price paid, or 21 days" do
      t = trade(4.0, 38, 1)

      for book <- ~w(ideas_half crash_puts_half) do
        assert {:hold, ^t} = at(book, t, 12.0)
        assert {:hold, ^t} = at(book, t, 4.5)
        assert {:close, ^t, [{_, 4.0}]} = at(book, t, 4.0)
      end

      t = trade(4.0, 21, 1)
      assert {:close, ^t, [{_, 9.0}]} = at("ideas_half", t, 9.0)
    end

    test "a crash put that sold half is still held: no new put is bought" do
      t = %{trade(3.0, 38, 2) | legs: [%{hd(trade(3.0, 38, 2).legs) | kind: "put"}]}
      chain = [row("put", 580.0, -0.10, 2.0, 2.06)]
      snap = %{snapshot(640.0, chain, %{}) | quotes: %{7 => %{bid: 6.0, ask: 6.1}}}

      assert [{:sell_half, ^t, _, 6.0}] =
               LongOptions.plan_crash_puts("crash_puts_half", [t], snap, 10_000.0, 0.1)
    end

    test "the half's cash" do
      [leg] = trade(4.0, 38, 2).legs
      # One contract sold at 8.00, less its commission.
      assert_in_delta Opus.Options.Paper.Legs.cash({:sell_half, nil, leg, 8.0}, 0.1),
                      799.9,
                      1.0e-9
    end
  end

  describe "take-profit alone (the resting order)" do
    test "ideas sell at double, half books sell half, crash puts have none, stops never fire" do
      quotes = fn bid -> %{7 => %{bid: bid, ask: bid * 1.02}} end
      one = trade(4.0)
      two = trade(4.0, 38, 2)

      assert {:close, ^one, [{_, 8.0}]} = LongOptions.take_profit("ideas", one, quotes.(8.0))
      assert {:hold, ^one} = LongOptions.take_profit("ideas", one, quotes.(1.0))
      assert {:sell_half, ^two, _, 8.0} = LongOptions.take_profit("ideas_half", two, quotes.(8.0))
      assert {:hold, ^one} = LongOptions.take_profit("ideas_half", one, quotes.(3.0))
      assert {:hold, ^one} = LongOptions.take_profit("crash_puts", one, quotes.(9.0))
      assert {:hold, ^one} = LongOptions.take_profit("ideas", one, %{})
    end
  end
end
