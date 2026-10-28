defmodule Opus.Trading.Recipe do
  @moduledoc """
  A strategy's recipe (table `strategies`): the rules with no instrument
  attached. Each `Opus.Trading.LiveStrategy` assigns a recipe to one
  instrument with its own sizing. research/strategy_assignments_plan.md.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Opus.Trading.Granularity

  @type t :: %__MODULE__{}

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "strategies" do
    field :name, :string
    field :granularity, :string
    field :definition, :map
    field :notes, :string

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @doc "A recipe's name, timeframe, rules and notes; the same rules can't be saved twice."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(recipe, attrs) do
    recipe
    |> cast(attrs, [:name, :granularity, :definition, :notes])
    |> validate_required([:name, :granularity, :definition], message: "is needed")
    |> validate_inclusion(:granularity, Granularity.all())
    |> unique_constraint(:definition,
      name: :strategies_recipe_key,
      message: "are the same as another strategy's"
    )
  end
end
