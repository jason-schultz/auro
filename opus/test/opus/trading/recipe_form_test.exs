defmodule Opus.Trading.RecipeFormTest do
  use ExUnit.Case, async: true

  alias Opus.Trading.RecipeForm

  # The running RSI(2) dip-buy recipe, as stored.
  @dip_buy %{
    "version" => "v1_composite",
    "strategy_id" => nil,
    "strategy_name" => "Index RSI(2) dip-buy",
    "components" => %{
      "r" => %{
        "type" => "RsiReversion",
        "params" => %{"rsi_period" => 2, "oversold" => 20.0, "overbought" => 80.0}
      },
      "t" => %{"type" => "MaFilter", "params" => %{"period" => 100, "ma_type" => "sma"}}
    },
    "entry" => %{"long" => %{"and" => ["r.long", "t.above"]}},
    "exit" => %{"long" => "r.exit_long"},
    "stop" => %{"type" => "AtrMultiple", "params" => %{"k" => 3.0, "period" => 14}},
    "max_hold_bars" => 10
  }

  test "a running recipe goes into the form and comes back out unchanged" do
    {:ok, form} = RecipeForm.from_definition(@dip_buy, "Index RSI(2) dip-buy", "D", nil)

    assert form["rules"]["entry_long"] == %{
             "mode" => "and",
             "refs" => ["r.long", "t.above"],
             "timing" => %{}
           }

    assert form["hold"] == "10"
    assert RecipeForm.to_definition(form, @dip_buy) == @dip_buy
  end

  test "a new block gets a key of its own and settings at its defaults" do
    form =
      RecipeForm.new()
      |> RecipeForm.add_component("RsiReversion")
      |> RecipeForm.add_component("RsiReversion")

    assert [%{"key" => "r"}, %{"key" => "r2", "params" => %{"rsi_period" => "2"}}] =
             form["components"]

    assert {"r2.long", "RSI(2) is below 20"} in RecipeForm.choices(form)
  end

  test "removing a block drops the rules that used it" do
    {:ok, form} = RecipeForm.from_definition(@dip_buy, "x", "D", nil)
    form = RecipeForm.remove_component(form, "t")

    assert form["rules"]["entry_long"]["refs"] == ["r.long"]
    assert RecipeForm.to_definition(form, %{})["entry"] == %{"long" => "r.long"}
  end

  test "typed numbers become numbers, a fixed stop a negative fraction, an empty hold none" do
    form =
      RecipeForm.new()
      |> RecipeForm.add_component("Momentum")
      |> put_in(["components", Access.at(0), "params", "lookback"], "5")
      |> Map.put("stop", %{"type" => "FixedPct", "params" => %{"pct" => "2"}})

    definition = RecipeForm.to_definition(form, %{})

    assert definition["components"]["mo"]["params"] == %{"lookback" => 5}
    assert definition["stop"] == %{"type" => "FixedPct", "params" => %{"pct" => -0.02}}
    assert definition["max_hold_bars"] == nil
    assert definition["version"] == "1"
  end

  test "a timed rule goes into the form and comes back out unchanged" do
    timed =
      @dip_buy
      |> put_in(["entry", "long"], %{
        "and" => ["r.long", %{"within" => 5, "rule" => "t.above"}]
      })
      |> put_in(["exit", "long"], %{"ago" => 1, "rule" => "r.exit_long"})

    {:ok, form} = RecipeForm.from_definition(timed, "Index RSI(2) dip-buy", "D", nil)

    assert form["rules"]["entry_long"]["timing"] == %{
             "t.above" => %{"kind" => "within", "bars" => "5"}
           }

    assert form["rules"]["exit_long"] == %{
             "mode" => "and",
             "refs" => ["r.exit_long"],
             "timing" => %{"r.exit_long" => %{"kind" => "ago", "bars" => "1"}}
           }

    assert RecipeForm.to_definition(form, timed) == timed
  end

  test "a timed count that isn't 1 to 500 falls back to the default; removing drops the timing" do
    form =
      RecipeForm.new()
      |> RecipeForm.add_component("Bollinger")
      |> RecipeForm.add_ref("entry_long", "bb.squeeze")
      |> RecipeForm.add_ref("entry_long", "bb.above_band")
      |> put_in(["rules", "entry_long", "timing"], %{
        "bb.squeeze" => %{"kind" => "within", "bars" => "0"},
        "bb.above_band" => %{"kind" => "ago", "bars" => "abc"}
      })

    assert RecipeForm.to_definition(form, %{})["entry"]["long"] == %{
             "and" => [
               %{"within" => 5, "rule" => "bb.squeeze"},
               %{"ago" => 1, "rule" => "bb.above_band"}
             ]
           }

    form = RecipeForm.remove_ref(form, "entry_long", "bb.squeeze")
    assert Map.keys(form["rules"]["entry_long"]["timing"]) == ["bb.above_band"]

    form = RecipeForm.remove_component(form, "bb")
    assert form["rules"]["entry_long"]["timing"] == %{}
  end

  test "a time rule around several conditions, or one condition twice, can't be edited here" do
    around =
      put_in(@dip_buy, ["entry", "long"], %{
        "within" => 3,
        "rule" => %{"and" => ["r.long", "t.above"]}
      })

    assert {:error, :too_complex} = RecipeForm.from_definition(around, "x", "D", nil)

    twice =
      put_in(@dip_buy, ["entry", "long"], %{
        "and" => ["r.long", %{"ago" => 1, "rule" => "r.long"}]
      })

    assert {:error, :too_complex} = RecipeForm.from_definition(twice, "x", "D", nil)
  end

  test "rules nested deeper than all-of or any-of can't be edited here" do
    nested = put_in(@dip_buy, ["entry", "long"], %{"and" => ["r.long", %{"not" => "t.above"}]})
    assert {:error, :too_complex} = RecipeForm.from_definition(nested, "x", "D", nil)
  end

  test "an opening-range recipe saved before the new settings comes back with them off" do
    old = %{
      "components" => %{"or" => %{"type" => "OpeningRange", "params" => %{"minutes" => 30}}},
      "entry" => %{"long" => "or.breakout_long"},
      "exit" => %{"long" => "or.session_close"},
      "stop" => %{"type" => "FromComponent", "params" => %{"component" => "or"}}
    }

    {:ok, form} = RecipeForm.from_definition(old, "ORB", "M5", nil)
    definition = RecipeForm.to_definition(form, old)

    assert definition["components"]["or"]["params"] == %{
             "minutes" => 30,
             "first_breakout_only" => false,
             "no_entry_before_close" => nil
           }

    assert definition["stop"] == old["stop"]
    assert "OpeningRange" in RecipeForm.own_stop()
  end

  test "a yes/no setting becomes true or false and a guard typed in becomes a number" do
    form =
      RecipeForm.new()
      |> RecipeForm.add_component("OpeningRange")
      |> put_in(["components", Access.at(0), "params", "first_breakout_only"], "true")
      |> put_in(["components", Access.at(0), "params", "no_entry_before_close"], "15")

    params = RecipeForm.to_definition(form, %{})["components"]["or"]["params"]
    assert params["first_breakout_only"] == true
    assert params["no_entry_before_close"] == 15
  end

  test "new Bollinger and carry blocks start at their defaults" do
    form =
      RecipeForm.new()
      |> RecipeForm.add_component("Bollinger")
      |> RecipeForm.add_component("Carry")

    components = RecipeForm.to_definition(form, %{})["components"]
    assert components["bb"]["params"]["squeeze_lookback"] == 120
    assert components["c"]["params"] == %{"min_spread" => 0.25}
  end
end
