defmodule Opus.Options.SpotTest do
  use ExUnit.Case, async: true

  alias Opus.Options.Spot

  test "the quotes' last trades, keyed by the ticker asked for, with their time" do
    quotes = [
      %{
        "requested" => "SPY",
        "symbol" => "SPY",
        "last_trade_price" => 757.12,
        "last_trade_time" => "2026-10-30T19:59:58.000000-04:00"
      },
      %{"requested" => "IWM", "symbol" => "IWM", "last_trade_price" => nil},
      %{"symbol" => "QQQ", "last_trade_price" => 692, "last_trade_time" => "garbled"}
    ]

    assert %{
             "SPY" => %{price: 757.12, at: ~U[2026-10-30 23:59:58.000000Z]},
             "QQQ" => %{price: 692.0, at: nil}
           } == Spot.from_quotes(quotes)
  end

  test "no engine, no prices" do
    assert Spot.now([]) == %{}
    assert Spot.now(["SPY"]) == %{}
  end
end
