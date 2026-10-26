defmodule Opus.Options.Paper.LegsTest do
  use ExUnit.Case, async: true

  alias Opus.Options.Paper.Legs

  defp leg(kind, side, strike, open_price),
    do: %{kind: kind, side: side, strike: strike, open_price: open_price, quantity: 1}

  test "a put credit spread loses at most its width less the credit" do
    legs = [leg("put", "short", 640.0, 6.40), leg("put", "long", 620.0, 2.40)]
    s = Legs.summary(legs)

    assert_in_delta s.net, 400.0, 1.0e-9
    assert_in_delta s.max_profit, 400.0, 1.0e-9
    assert_in_delta s.max_loss, 1_600.0, 1.0e-9
    assert [breakeven] = s.breakevens
    assert_in_delta breakeven, 636.0, 1.0e-9
    assert_in_delta Legs.at_expiry(legs, 500.0), -1_600.0, 1.0e-9
  end

  test "an iron condor has two break-evens and capped risk both ways" do
    legs = [
      leg("put", "long", 600.0, 1.0),
      leg("put", "short", 610.0, 2.0),
      leg("call", "short", 690.0, 2.0),
      leg("call", "long", 700.0, 1.0)
    ]

    s = Legs.summary(legs)
    assert_in_delta s.max_profit, 200.0, 1.0e-9
    assert_in_delta s.max_loss, 800.0, 1.0e-9
    assert [low, high] = s.breakevens
    assert_in_delta low, 608.0, 1.0e-9
    assert_in_delta high, 692.0, 1.0e-9
  end

  test "a bought call's gain is unlimited and its loss the premium" do
    s = Legs.summary([leg("call", "long", 660.0, 5.0)])
    assert s.max_profit == nil
    assert_in_delta s.max_loss, 500.0, 1.0e-9
    assert s.breakevens == [665.0]
    assert_in_delta s.net, -500.0, 1.0e-9
  end

  test "cash follows the fills and the commission" do
    legs = [leg("put", "short", 640.0, 6.40), leg("put", "long", 620.0, 2.40)]
    [short, long] = legs

    assert_in_delta Legs.open_cash(legs, 0.10), 640.0 - 240.0 - 0.20, 1.0e-9

    assert_in_delta Legs.close_cash([{short, 3.0}, {long, 1.0}], 0.10),
                    -300.0 + 100.0 - 0.20,
                    1.0e-9

    # Settled at intrinsic with the underlying at 630: the short pays 10, the long nothing.
    assert_in_delta Legs.settle_cash(legs, 630.0), -1_000.0, 1.0e-9
  end
end
