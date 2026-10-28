defmodule Opus.Trading.RecipesTest do
  use Opus.DataCase, async: false

  alias Opus.Instruments
  alias Opus.Pipeline.StrategyConfig
  alias Opus.Trading.{LiveStrategy, LiveTrade, Recipe, Recipes, StrategyResults}

  @definition %{
    "version" => "1",
    "strategy_name" => "Momentum test",
    "components" => %{"mo" => %{"type" => "Momentum", "params" => %{"lookback" => 5}}},
    "entry" => %{"long" => "mo.up"},
    "exit" => %{"long" => "mo.down"},
    "stop" => %{"type" => "FixedPct", "params" => %{"pct" => -0.02}}
  }

  setup do
    for schema <- [LiveTrade, LiveStrategy, Recipe], do: Repo.delete_all(schema)
    :ok
  end

  defp assign!(instrument, enabled) do
    now = DateTime.utc_now()

    Repo.insert!(%LiveStrategy{
      strategy_type: "composite",
      instrument: instrument,
      granularity: "D",
      parameters:
        Map.merge(@definition, %{
          "instrument" => instrument,
          "granularity" => "D",
          "sizing" => %{"type" => "RiskPct", "params" => %{"pct" => 0.01}}
        }),
      enabled: enabled,
      created_at: now,
      updated_at: now
    })
  end

  test "a recipe that's trading can't be deleted; a draft can" do
    assign!("SPX500_USD", true)
    trading = Repo.one!(Recipe)
    assert {:error, :locked} = Recipes.delete(trading)

    {:ok, draft} =
      Recipes.create(%{
        name: "Draft",
        granularity: "D",
        definition: Map.put(@definition, "strategy_name", "Draft")
      })

    assert {:ok, _} = Recipes.delete(draft)
    refute Repo.get(Recipe, draft.id)
  end

  test "the same rules can't be saved twice" do
    attrs = %{name: "One", granularity: "D", definition: @definition}

    assert {:ok, _} = Recipes.create(attrs)
    assert {:error, changeset} = Recipes.create(%{attrs | name: "Two"})
    assert %{definition: ["are the same as another strategy's"]} = errors_on(changeset)
  end

  test "an edit is refused while any instrument is switched on" do
    assign!("SPX500_USD", true)
    recipe = Repo.one!(Recipe)

    assert {:error, :locked} = Recipes.update(recipe, %{name: "Renamed"})
  end

  test "an edit changes every instrument's rules and keeps them on this recipe" do
    spx = assign!("SPX500_USD", false)
    eu = assign!("EU50_EUR", false)
    recipe = Repo.one!(Recipe)
    edited = put_in(@definition, ["components", "mo", "params", "lookback"], 10)

    assert {:ok, saved} = Recipes.update(recipe, %{definition: edited})
    assert saved.id == recipe.id

    for %{id: id, instrument: instrument} <- [spx, eu] do
      reloaded = Repo.get!(LiveStrategy, id)
      assert reloaded.strategy_id == recipe.id
      assert reloaded.parameters["components"]["mo"]["params"]["lookback"] == 10
      assert reloaded.parameters["instrument"] == instrument
      assert reloaded.sizing == %{"type" => "RiskPct", "params" => %{"pct" => 0.01}}
    end

    assert Repo.aggregate(Recipe, :count) == 1
  end

  test "the timeframe can't change under instruments that run it" do
    assign!("SPX500_USD", false)
    recipe = Repo.one!(Recipe)

    assert {:error, :timeframe_in_use} = Recipes.update(recipe, %{granularity: "H1"})
  end

  defp bar!(instrument, at) do
    {:ok, id} =
      case Instruments.id_for(instrument) do
        {:ok, id} -> {:ok, id}
        :error -> with {:ok, i} <- Instruments.add(instrument, "index"), do: {:ok, i.id}
      end

    Repo.insert_all("candles", [
      %{
        instrument_id: id,
        instrument: instrument,
        granularity: "D",
        timestamp: at,
        open: 1.0,
        high: 1.0,
        low: 1.0,
        close: 1.0,
        complete: true
      }
    ])
  end

  test "an instrument whose bars all come after the holdout start can't be tested" do
    bar!("SPX500_USD", ~U[2026-07-20 20:00:00Z])
    {:ok, recipe} = Recipes.create(%{name: "Draft", granularity: "D", definition: @definition})

    assert {:error, {:no_history, first, ~D[2025-10-17]}} =
             Recipes.run_tests(recipe, "SPX500_USD")

    assert DateTime.compare(first, ~U[2026-07-20 20:00:00Z]) == :eq
  end

  test "running the tests sends the recipe on the instrument through the pipeline" do
    bar!("SPX500_USD", ~U[2024-03-01 20:00:00Z])
    {:ok, recipe} = Recipes.create(%{name: "Draft", granularity: "D", definition: @definition})

    assert {:ok, %StrategyConfig{instrument: "SPX500_USD"}} =
             Recipes.run_tests(recipe, "SPX500_USD")

    assert [%{instrument: "SPX500_USD", stages: %{backtest: %{status: :pending}}}] =
             StrategyResults.for_recipe(recipe.definition)
  end
end
