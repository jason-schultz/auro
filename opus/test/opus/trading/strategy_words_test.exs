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

  # Zarattini, Barbon & Aziz (2023): the first 5-minute bar's direction,
  # stopped at the other side of that bar, out at the close.
  @first_bar %{
    "components" => %{
      "or" => %{
        "type" => "OpeningRange",
        "params" => %{
          "minutes" => 5,
          "first_breakout_only" => false,
          "no_entry_before_close" => nil
        }
      }
    },
    "entry" => %{"long" => "or.first_bar_up", "short" => "or.first_bar_down"},
    "exit" => %{"long" => "or.session_close", "short" => "or.session_close"},
    "stop" => %{"type" => "FromComponent", "params" => %{"component" => "or"}}
  }

  test "the first-bar opening-range strategy reads as its rules" do
    rules = Map.new(StrategyWords.rules(@first_bar, "M5"))

    assert rules["Buy when"] ==
             "the first 5 minutes after the US open end above the 09:30 open (decided as they end)"

    assert rules["Sell short when"] =~ "end below the 09:30 open"

    assert rules["Stop"] ==
             "the other side of the opening range (its low for a buy, its high for a short)"
  end

  test "first-breakout-only and the closing guard show in the opening-range rules" do
    definition =
      put_in(@first_bar, ["components", "or", "params"], %{
        "minutes" => 30,
        "first_breakout_only" => true,
        "no_entry_before_close" => 15
      })

    assert StrategyWords.phrase(definition, "or.breakout_long", "M5") ==
             "the price breaks above the high of the first 30 minutes after the US open " <>
               "for the first time that day, but not in the last 15 minutes before the close"

    guard_zero = put_in(definition, ["components", "or", "params", "no_entry_before_close"], 0)

    assert StrategyWords.phrase(guard_zero, "or.first_bar_up", "M5") =~
             "but not on the closing bar"
  end

  test "carry and the Bollinger squeeze read in plain words" do
    definition = %{
      "components" => %{
        "c" => %{"type" => "Carry", "params" => %{"min_spread" => 0.5}},
        "bb" => %{
          "type" => "Bollinger",
          "params" => %{
            "period" => 20,
            "std_dev_mult" => 2.0,
            "squeeze_lookback" => 120,
            "squeeze_within" => 5
          }
        }
      }
    }

    assert StrategyWords.phrase(definition, "c.long", "D") ==
             "the first currency's central-bank rate is at least 0.5 percentage points above the second's (holding it earns)"

    assert StrategyWords.phrase(definition, "bb.squeeze", "D") ==
             "the Bollinger bands (over 20 days) are the narrowest in 120 days: a squeeze"

    assert StrategyWords.phrase(definition, "bb.squeeze_recent", "D") ==
             "the Bollinger bands (over 20 days) were squeezed, the narrowest in 120 days, at some point in the last 5 days"
  end

  test "timed rules say when the condition had to hold" do
    definition = %{
      "components" => %{
        "bb" => %{"type" => "Bollinger", "params" => %{"period" => 20, "std_dev_mult" => 2.0}},
        "t" => %{"type" => "MaFilter", "params" => %{"period" => 100}}
      },
      "entry" => %{
        "long" => %{
          "and" => [
            %{"within" => 5, "rule" => "bb.squeeze"},
            "bb.above_band",
            %{"ago" => 1, "rule" => %{"or" => ["t.above", "bb.above_middle"]}}
          ]
        }
      },
      "exit" => %{"long" => %{"within" => 1, "rule" => "t.below"}}
    }

    rules = Map.new(StrategyWords.rules(definition, "D"))

    assert rules["Buy when"] ==
             "at some point in the last 5 days, the Bollinger bands (over 20 days) are the narrowest in 120 days: a squeeze" <>
               " and the price closes above its upper Bollinger band (2 normal wobbles over its average over 20 days)" <>
               " and 1 day ago, (the price is above its simple average over 100 days, or the price is back up to its average over 20 days)"

    # "Within 1 bar" is the condition itself.
    assert rules["Close the buy when"] == "the price is below its simple average over 100 days"

    assert StrategyWords.refs(get_in(definition, ["entry", "long"])) ==
             ["bb.squeeze", "bb.above_band", "t.above", "bb.above_middle"]

    assert StrategyWords.phrase(definition, "t.above", "H1") =~ "100 hours"

    assert StrategyWords.selector(
             %{
               "components" => definition["components"],
               "x" => %{"ago" => 3, "rule" => "t.above"}
             },
             ["x"],
             "H1"
           ) == "3 hours ago, the price is above its simple average over 100 hours"
  end
end
