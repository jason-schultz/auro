defmodule Opus.Trading.StrategyWordsTest do
  use ExUnit.Case, async: true

  alias Opus.Trading.StrategyWords

  # The recipes running on Oct 27 2026, as stored in `strategies.definition`.
  @dip_buy %{
    "components" => %{
      "r" => %{
        "type" => "RsiReversion",
        "params" => %{"rsi_period" => 2, "oversold" => 20, "overbought" => 80}
      },
      "t" => %{"type" => "MaFilter", "params" => %{"period" => 100, "ma_type" => "sma"}}
    },
    "entry" => %{"long" => %{"and" => ["r.long", "t.above"]}},
    "exit" => %{"long" => "r.exit_long"},
    "stop" => %{"type" => "AtrMultiple", "params" => %{"k" => 3.0, "period" => 14}},
    "max_hold_bars" => 10
  }

  @noise_area %{
    "components" => %{
      "na" => %{
        "type" => "NoiseArea",
        "params" => %{"band_mult" => 1.0, "lookback_sessions" => 14}
      }
    },
    "entry" => %{"long" => "na.long", "short" => "na.short"},
    "exit" => %{
      "long" => %{"or" => ["na.exit_long", "na.session_close"]},
      "short" => %{"or" => ["na.exit_short", "na.session_close"]}
    },
    "stop" => %{"type" => "FromComponent", "params" => %{"component" => "na"}},
    "max_hold_bars" => nil
  }

  test "the RSI(2) dip-buy reads as its rules, long only" do
    assert StrategyWords.rules(@dip_buy, "D") == [
             {"Buy when",
              "RSI(2) is below 20 and the price is above its simple average over 100 days"},
             {"Close the buy when", "RSI(2) is back to 50 or higher"},
             {"Stop", "3 × the average range (ATR over 14 days) away from the entry"},
             {"Hold limit", "closes after 10 days if nothing else has"},
             {"Direction", "buys only; it never sells short"}
           ]
  end

  test "the noise-area strategy trades both ways and stops at the band" do
    rules = Map.new(StrategyWords.rules(@noise_area, "M5"))

    assert rules["Buy when"] =~ "breaks above the noise band"
    assert rules["Sell short when"] =~ "breaks below the noise band"

    assert rules["Close the buy when"] ==
             "the price falls back below the band or the day's average price (VWAP), " <>
               "or the US session ends (16:00 New York)"

    assert rules["Stop"] == "the other side of the noise band"
    refute Map.has_key?(rules, "Direction")
    refute Map.has_key?(rules, "Hold limit")
  end

  test "an unknown component's port stays readable as its raw name" do
    definition = %{
      "components" => %{"x" => %{"type" => "Shiny", "params" => %{}}},
      "entry" => %{"long" => "x.go"}
    }

    assert [{"Buy when", "x.go"} | _] = StrategyWords.rules(definition, "H1")
  end

  test "sizing and timeframe in words" do
    assert StrategyWords.sizing(%{"type" => "RiskPct", "params" => %{"pct" => 0.005}}) ==
             "Risks 0.5% of the account per trade"

    assert StrategyWords.sizing(%{
             "type" => "RiskPct",
             "params" => %{"pct" => 0.01, "max_notional_pct" => 1.5}
           }) ==
             "Risks 1% of the account per trade, with the position capped at 150% of the account"

    assert StrategyWords.timeframe("D") == "daily bars"
    assert StrategyWords.timeframe("M5") == "5-minute bars"
  end
end
