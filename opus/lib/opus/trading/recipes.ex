defmodule Opus.Trading.Recipes do
  @moduledoc """
  Saving strategy recipes from the builder (`OpusWeb.StrategyBuilderLive`).

  - A new recipe, or an edited copy, is a new `strategies` row. It runs
    nowhere until it's tested on an instrument (`run_tests/2`); the
    pipeline adds it, switched off, to that instrument when every stage
    passes.
  - Editing a recipe in place is refused while it's locked: any of its
    instruments switched on or holding an open trade. The rules of every
    instrument it runs on change together, in one transaction.
  - While `live_strategies.parameters` is still what the engine's writers
    send (research/strategy_assignments_plan.md, phase 1), an in-place edit
    writes each assignment's full strategy JSON too, so the database bridge
    links it back to this same recipe.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Opus.Instruments
  alias Opus.Pipeline.Coordinator
  alias Opus.Repo
  alias Opus.Trading.{LiveStrategy, Recipe, Strategies, StrategyWords}

  @doc "A recipe by id, or nil."
  @spec get(String.t()) :: Recipe.t() | nil
  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Recipe, uuid)
      :error -> nil
    end
  end

  @doc "The instruments a recipe runs on: id, instrument, enabled, open trades, sizing words."
  @spec assignments(Ecto.UUID.t()) :: [map()]
  def assignments(recipe_id) do
    members =
      LiveStrategy
      |> where([s], s.strategy_id == ^recipe_id)
      |> order_by([s], desc: s.enabled, asc: s.instrument)
      |> Repo.all()

    open =
      from(t in "live_trades",
        where:
          t.status == "open" and
            t.live_strategy_id in type(^Enum.map(members, & &1.id), {:array, Ecto.UUID}),
        group_by: t.live_strategy_id,
        select: {type(t.live_strategy_id, Ecto.UUID), count(t.id)}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(members, fn s ->
      %{
        id: s.id,
        instrument: s.instrument,
        granularity: s.granularity,
        enabled: s.enabled,
        open_trades: Map.get(open, s.id, 0),
        sizing: s.sizing,
        sizing_words: StrategyWords.sizing(s.sizing)
      }
    end)
  end

  @doc "The assignments keeping a recipe locked: switched on, or holding an open trade."
  @spec locked_by([map()]) :: [map()]
  def locked_by(assignments), do: Enum.filter(assignments, &(&1.enabled or &1.open_trades > 0))

  @doc "Save a new recipe. Rules identical to an existing recipe are refused."
  @spec create(map()) :: {:ok, Recipe.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: %Recipe{} |> Recipe.changeset(attrs) |> Repo.insert()

  @doc """
  Change a recipe's name, notes and rules where it is, for every instrument
  it runs on. Refused while it's locked, and when it runs anywhere and the
  timeframe would change (that's a different strategy: save a copy).
  """
  @spec update(Recipe.t(), map()) ::
          {:ok, Recipe.t()} | {:error, :locked | :timeframe_in_use | Ecto.Changeset.t()}
  def update(%Recipe{} = recipe, attrs) do
    assignments = assignments(recipe.id)
    changeset = Recipe.changeset(recipe, attrs)

    cond do
      locked_by(assignments) != [] ->
        {:error, :locked}

      assignments != [] and Ecto.Changeset.changed?(changeset, :granularity) ->
        {:error, :timeframe_in_use}

      true ->
        assignments
        |> Enum.reduce(Multi.update(Multi.new(), :recipe, changeset), fn a, multi ->
          Multi.update_all(
            multi,
            {:assignment, a.id},
            fn %{recipe: saved} ->
              params = Strategies.compose(saved.definition, a.instrument, a.granularity, a.sizing)
              from(s in LiveStrategy, where: s.id == ^a.id, update: [set: [parameters: ^params]])
            end,
            []
          )
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{recipe: saved}} -> {:ok, saved}
          {:error, :recipe, changeset, _} -> {:error, changeset}
        end
    end
  end

  @doc """
  Delete a recipe and the instruments it's assigned to (through the
  engine, which owns that). Refused while it's locked. Its test history
  stays in the pipeline tables.
  """
  @spec delete(Recipe.t()) ::
          {:ok, Recipe.t()} | {:error, :locked | {:engine, [{String.t(), term()}]}}
  def delete(%Recipe{} = recipe) do
    assignments = assignments(recipe.id)

    failures =
      if locked_by(assignments) == [],
        do:
          Enum.flat_map(assignments, fn a ->
            case Strategies.delete(a.id) do
              {:ok, _} -> []
              {:error, reason} -> [{a.instrument, reason}]
            end
          end),
        else: :locked

    case failures do
      :locked -> {:error, :locked}
      [] -> Repo.delete(recipe)
      failures -> {:error, {:engine, failures}}
    end
  end

  @doc """
  Switch off every instrument the recipe is on, through the engine (which
  owns the switch). Returns the instruments it couldn't switch off with why.
  """
  @spec switch_off([map()]) :: :ok | {:error, [{String.t(), term()}]}
  def switch_off(assignments) do
    assignments
    |> Enum.filter(& &1.enabled)
    |> Enum.flat_map(fn a ->
      case Strategies.toggle(a.id) do
        {:ok, %{"enabled" => false}} -> []
        {:ok, _still_on} -> [{a.instrument, :still_on}]
        {:error, reason} -> [{a.instrument, reason}]
      end
    end)
    |> case do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  @doc """
  Send the recipe through the tests on `instrument`: backtest, then
  walk-forward, Monte Carlo and holdout. Passing every stage adds it to
  that instrument, switched off, at the default size.
  """
  @spec run_tests(Recipe.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def run_tests(%Recipe{} = recipe, instrument) do
    with :ok <- testable(instrument, recipe.granularity) do
      submit(recipe, instrument)
    end
  end

  @doc """
  Whether the tests can run on `instrument` at `granularity`: they only use
  bars from before the sealed holdout window starts
  (`trading_config.pipeline_holdout_start`), so an instrument whose bars
  all came later can be previewed but not tested; and only markets with a
  broker set for their tests (its costs are what they're graded on).
  `{:error, {:no_history, first_bar, holdout_start}}` says why not.
  """
  @spec testable(String.t(), String.t()) ::
          :ok
          | {:error, {:no_history, DateTime.t() | nil, Date.t()}}
          | {:error, {:no_broker | :no_dividends, [String.t()]}}
  def testable(instrument, granularity) do
    case Instruments.untestable([instrument]) do
      nil -> history(instrument, granularity)
      why -> {:error, why}
    end
  end

  defp history(instrument, granularity) do
    holdout = holdout_start()
    before = DateTime.new!(holdout, ~T[00:00:00], "Etc/UTC")

    bars =
      from(c in "candles", where: c.instrument == ^instrument and c.granularity == ^granularity)

    if Repo.exists?(where(bars, [c], c.timestamp < ^before)) do
      :ok
    else
      first =
        bars
        |> select([c], type(min(c.timestamp), :utc_datetime_usec))
        |> Repo.one()

      {:error, {:no_history, first, holdout}}
    end
  end

  @doc "The first day of the sealed holdout window the tests never look at."
  @spec holdout_start() :: Date.t()
  def holdout_start do
    from(c in "trading_config", where: c.key == "pipeline_holdout_start", select: c.value)
    |> Repo.one()
    |> case do
      text when is_binary(text) -> Date.from_iso8601!(text)
      _ -> ~D[2025-10-17]
    end
  end

  defp submit(recipe, instrument) do
    Coordinator.submit_config(%{
      instrument: instrument,
      granularity: recipe.granularity,
      strategy_type: "composite",
      parameters:
        Strategies.compose(
          recipe.definition,
          instrument,
          recipe.granularity,
          Strategies.default_sizing()
        )
    })
  end
end
