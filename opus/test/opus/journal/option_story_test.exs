defmodule Opus.Journal.OptionStoryTest do
  use ExUnit.Case, async: true

  alias Opus.Journal.OptionStory

  defp leg(side, kind, strike, open, close, status \\ "closed"),
    do: %{
      side: side,
      kind: kind,
      strike: strike,
      quantity: 1,
      expiration: ~D[2026-12-04],
      open_price: open,
      close_price: close,
      status: status
    }

  defp trade(attrs),
    do:
      Map.merge(
        %{
          id: 1,
          book: "put_spread",
          symbol: "SPY",
          structure: "put_spread",
          opened_on: ~D[2026-10-26],
          closed_on: ~D[2026-10-29],
          ended: :closed
        },
        attrs
      )

  test "a credit spread closed early: premium taken in, what was bought back, the share kept" do
    t =
      trade(%{
        legs: [leg("long", "put", 250.0, 1.08, 0.49), leg("short", "put", 265.0, 2.64, 1.25)],
        opened_cash: 155.8,
        pnl: 79.6
      })

    story = OptionStory.tell(t)
    assert story.headline == "Kept $79.60 of $155.80 premium"
    assert story.result == :win

    assert {"The trade",
            "SPY: bought the $250.00 put at $1.08 and sold the $265.00 put at $2.64, expiring Dec 4"} in story.story

    assert {"How it ended",
            "Closed before expiry on Oct 29: sold the $250.00 put at $0.49 and bought back the $265.00 put at $1.25."} in story.story

    assert {"Result", "+$79.60", "51.1% of the premium kept"} in story.numbers
    assert {"Held", "3 days", nil} in story.numbers
  end

  test "a bought call: the cost and the return on it" do
    t =
      trade(%{
        book: "ideas",
        structure: "call",
        legs: [leg("long", "call", 700.0, 5.0, 8.0)],
        opened_cash: -501.0,
        pnl: 298.0
      })

    story = OptionStory.tell(t)
    assert story.headline == "+$298.00 on $501.00 paid (+59.5%)"
    assert {"Paid", "$501.00", nil} in story.numbers
  end

  test "an assigned put says the shares were bought; the premium is its result" do
    t =
      trade(%{
        book: "wheel",
        structure: "put",
        ended: :assigned,
        legs: [leg("short", "put", 260.0, 3.17, 0.0, "assigned")],
        opened_cash: 316.9,
        pnl: 316.9
      })

    story = OptionStory.tell(t)
    assert story.headline == "Assigned: 100 shares bought at $260.00"
    assert {"Result", "+$316.90", nil} in story.numbers
  end

  test "the tab's numbers: count, money-makers, P&L and premium kept" do
    trades = [
      trade(%{legs: [], opened_cash: 200.0, pnl: 100.0}),
      trade(%{legs: [], opened_cash: 100.0, pnl: -50.0}),
      trade(%{legs: [], opened_cash: -300.0, pnl: 60.0}),
      trade(%{legs: [], ended: :assigned, opened_cash: 300.0, pnl: 300.0})
    ]

    assert OptionStory.kpis(trades) == %{count: 4, won: 3, pnl: 410.0, kept: 50.0 / 300.0}
    assert OptionStory.kpis([]) == %{count: 0, won: 0, pnl: 0.0, kept: nil}
  end
end
