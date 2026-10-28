defmodule Opus.Trading.BlocksTest do
  use ExUnit.Case, async: true

  alias Opus.Trading.{Blocks, RecipeForm}

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
end
