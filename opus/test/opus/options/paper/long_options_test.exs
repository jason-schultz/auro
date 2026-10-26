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

  defp trade(open_price, dte \\ 38) do
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
          quantity: 1
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

    test "expired legs settle" do
      t = trade(4.0, 0)
      assert {:settle, ^t, 660.0} = LongOptions.manage("ideas", t, %{}, snapshot(660.0, [], %{}))
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
               LongOptions.plan_ideas([], ideas, snap, 100_000.0, 0.1, 0, MapSet.new())
    end

    test "never buys a contract twice and keeps at most 5 open", %{cheap: cheap, quotes: quotes} do
      snap = snapshot(650.0, [], quotes)
      ideas = [idea(cheap.contract_id)]
      held = MapSet.new([cheap.contract_id])
      assert [] = LongOptions.plan_ideas([], ideas, snap, 100_000.0, 0.1, 0, held)
      assert [] = LongOptions.plan_ideas([], ideas, snap, 100_000.0, 0.1, 5, MapSet.new())
    end

    test "needs the cash", %{cheap: cheap, quotes: quotes} do
      snap = snapshot(650.0, [], quotes)

      assert [] =
               LongOptions.plan_ideas(
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
               LongOptions.plan_crash_puts([], snap, 10_000.0, 0.1)

      old = %{trade(3.0, 21) | legs: [%{hd(trade(3.0, 21).legs) | kind: "put", strike: 570.0}]}
      snap = %{snap | quotes: %{7 => %{bid: 1.0, ask: 1.02}}}

      assert [{:close, ^old, _}, {:open, "long_put", _}] =
               LongOptions.plan_crash_puts([old], snap, 1_000.0, 0.1)
    end
  end
end
