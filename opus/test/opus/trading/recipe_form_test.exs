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

    assert form["rules"]["entry_long"] == %{"mode" => "and", "refs" => ["r.long", "t.above"]}
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

  test "rules nested deeper than all-of or any-of can't be edited here" do
    nested = put_in(@dip_buy, ["entry", "long"], %{"and" => ["r.long", %{"not" => "t.above"}]})
    assert {:error, :too_complex} = RecipeForm.from_definition(nested, "x", "D", nil)
  end
end
