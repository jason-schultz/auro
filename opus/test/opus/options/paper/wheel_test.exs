defmodule Opus.Options.Paper.WheelTest do
  use ExUnit.Case, async: true

  alias Opus.Options.Paper.Wheel

  @as_of ~D[2026-10-23]

  defp row(kind, strike, dte, delta, bid, ask) do
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

  defp leg(kind, strike, dte, open_price) do
    %{
      contract_id: 1,
      kind: kind,
      strike: strike,
      expiration: Date.add(@as_of, dte),
      open_price: open_price,
      quantity: 1
    }
  end

  defp snapshot(spot, quotes \\ %{}, chain \\ []),
    do: %{as_of: @as_of, spot: spot, quotes: quotes, chain: chain, expiry_spots: %{}}

  describe "fills" do
    test "need a bid and a spread within 10% of the mid" do
      assert Wheel.fillable?(%{bid: 5.0, ask: 5.2})
      refute Wheel.fillable?(%{bid: nil, ask: 0.05})
      refute Wheel.fillable?(%{bid: 0.0, ask: 0.05})
      refute Wheel.fillable?(%{bid: 1.0, ask: 1.2})
      refute Wheel.fillable?(nil)
    end
  end

  describe "pick/3" do
    test "the put 30–45 days out with delta nearest −0.25, skipping what can't fill" do
      chain = [
        row("put", 590.0, 38, -0.24, 4.0, 4.1),
        row("put", 600.0, 38, -0.31, 6.0, 6.2),
        row("put", 595.0, 20, -0.25, 3.0, 3.1),
        row("put", 595.0, 60, -0.25, 7.0, 7.1),
        row("put", 592.0, 38, -0.25, 4.5, 6.0),
        row("call", 640.0, 38, 0.25, 4.0, 4.1)
      ]

      assert %{strike: 590.0} = Wheel.pick(chain, "put", 0.0)
      assert Wheel.pick([], "put", 0.0) == nil
    end

    test "a call nearest 0.30 delta, never below the shares' cost" do
      chain = [row("call", 595.0, 40, 0.31, 5.0, 5.1), row("call", 610.0, 40, 0.22, 3.0, 3.1)]

      assert %{strike: 595.0} = Wheel.pick(chain, "call", 590.0)
      assert %{strike: 610.0} = Wheel.pick(chain, "call", 600.0)
      assert Wheel.pick(chain, "call", 620.0) == nil
    end
  end

  describe "manage/3" do
    test "buys back once half the premium is captured" do
      put = leg("put", 590.0, 30, 4.0)
      assert {:close, ^put, 1.95} = Wheel.manage(put, %{bid: 1.9, ask: 1.95}, snapshot(610.0))
      assert {:hold, ^put} = Wheel.manage(put, %{bid: 2.5, ask: 2.6}, snapshot(610.0))
    end

    test "at 21 days closes an out-of-the-money leg and holds one in the money" do
      put = leg("put", 590.0, 21, 4.0)
      assert {:close, ^put, 3.1} = Wheel.manage(put, %{bid: 3.0, ask: 3.1}, snapshot(600.0))
      assert {:hold, ^put} = Wheel.manage(put, %{bid: 9.0, ask: 9.2}, snapshot(582.0))
    end

    test "holds when the quote can't fill" do
      put = leg("put", 590.0, 10, 4.0)
      assert {:hold, ^put} = Wheel.manage(put, nil, snapshot(600.0))
    end

    test "settles at expiry against the expiry-day close" do
      put = leg("put", 590.0, 0, 4.0)
      call = leg("call", 610.0, -1, 3.0)

      assert {:assign, ^put} = Wheel.manage(put, nil, snapshot(585.0))
      assert {:expire, ^put} = Wheel.manage(put, nil, snapshot(595.0))
      assert {:call_away, ^call} = Wheel.manage(call, nil, snapshot(615.0))

      # A missed night settles on the expiry date's close, not tonight's.
      late = %{snapshot(580.0) | expiry_spots: %{call.expiration => 605.0}}
      assert {:expire, ^call} = Wheel.manage(call, nil, late)
    end
  end

  describe "plan/4" do
    setup do
      chain = [row("put", 590.0, 38, -0.25, 4.0, 4.1), row("call", 600.0, 38, 0.30, 5.0, 5.1)]
      %{chain: chain}
    end

    test "sells a cash-secured put when nothing is open and the cash is there", %{chain: chain} do
      assert [{:open, %{kind: "put", strike: 590.0}}] =
               Wheel.plan(%{legs: [], shares: nil}, snapshot(610.0, %{}, chain), 100_000.0, 0.1)
    end

    test "doesn't sell a put it can't secure", %{chain: chain} do
      assert [] = Wheel.plan(%{legs: [], shares: nil}, snapshot(610.0, %{}, chain), 50_000.0, 0.1)
    end

    test "an open leg that's held blocks a new one", %{chain: chain} do
      put = leg("put", 590.0, 30, 4.0)
      quotes = %{1 => %{bid: 3.0, ask: 3.1}}

      assert [{:hold, ^put}] =
               Wheel.plan(%{legs: [put], shares: nil}, snapshot(610.0, quotes, chain), 0.0, 0.1)
    end

    test "assignment turns into a covered call at or above the strike", %{chain: chain} do
      put = leg("put", 595.0, 0, 4.0)

      assert [{:assign, ^put}, {:open, %{kind: "call", strike: 600.0}}] =
               Wheel.plan(%{legs: [put], shares: nil}, snapshot(585.0, %{}, chain), 0.0, 0.1)
    end

    test "a call-away frees the cash for the next put", %{chain: chain} do
      call = leg("call", 600.0, 0, 3.0)
      lot = %{quantity: 100, open_price: 595.0}

      assert [{:call_away, ^call}, {:open, %{kind: "put"}}] =
               Wheel.plan(%{legs: [call], shares: lot}, snapshot(605.0, %{}, chain), 0.0, 0.1)
    end
  end

  test "cash moves with each action" do
    put = leg("put", 590.0, 0, 4.0)

    assert Wheel.cash({:open, %{bid: 4.0}}, 0.1) == 399.9
    assert Wheel.cash({:close, put, 2.0}, 0.1) == -200.1
    assert Wheel.cash({:assign, put}, 0.1) == -59_000.0
    assert Wheel.cash({:call_away, %{put | kind: "call"}}, 0.1) == 59_000.0
    assert Wheel.cash({:expire, put}, 0.1) == 0.0
  end
end
