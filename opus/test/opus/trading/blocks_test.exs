defmodule Opus.Trading.BlocksTest do
  use ExUnit.Case, async: true

  alias Opus.Trading.{Blocks, RecipeForm, StrategyWords}

  test "every block explains itself and every setting" do
    for b <- Blocks.all() do
      assert b.watches =~ ~r/\.$/, "#{b.type} needs a one-sentence explanation"
      assert b.group in Enum.map(Blocks.groups(), &elem(&1, 0))
      for p <- b.params, do: assert(p.help != "", "#{b.type}.#{p.key} needs help text")
    end
  end

  test "reference levels come from the block's own settings" do
    mr = Blocks.get("MeanReversion")
    z = Enum.find(mr.draw, &(&1.key == "z"))

    assert Blocks.levels(z, %{"entry_z_threshold" => "2", "stop_z_threshold" => 3.0}) ==
             [-3.0, -2.0, 0.0, 2.0, 3.0]
  end

  test "every rule of every block reads as a sentence at its default settings" do
    for b <- Blocks.all(), granularity <- ["D", "M5"] do
      form =
        RecipeForm.new()
        |> Map.put("granularity", granularity)
        |> RecipeForm.add_component(b.type)

      for {ref, words} <- RecipeForm.choices(form) do
        refute words == ref, "#{b.type} #{ref} has no plain words"
      end
    end
  end

  test "every block in the engine's catalog is in a builder group or hidden" do
    for b <- Blocks.catalog() do
      assert Blocks.get(b.type) || b.type in Blocks.hidden(),
             "#{b.type} needs a group in Opus.Trading.Blocks (or a place in @hidden)"
    end

    # A group naming a type the catalog doesn't have would drop it silently.
    assert length(Blocks.all()) == length(Blocks.catalog()) - length(Blocks.hidden())
  end

  test "every port and own stop of every engine block reads as words when its settings are left out" do
    for b <- Blocks.catalog() do
      definition = %{
        "components" => %{"x" => %{"type" => b.type, "params" => %{}}},
        "stop" => %{"type" => "FromComponent", "params" => %{"component" => "x"}}
      }

      for port <- b.ports do
        refute StrategyWords.phrase(definition, "x.#{port}", "D") == "x.#{port}",
               "#{b.type}.#{port} has no plain words"
      end

      stop = definition |> StrategyWords.rules("D") |> Map.new() |> Map.fetch!("Stop")
      if b.stop, do: refute(stop == "set by x", "#{b.type}'s own stop has no words")
    end
  end
end
