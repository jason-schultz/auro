defmodule Opus.Pipeline.StrategyConfig do
  @moduledoc """
  Ecto schema for submitted strategy configs entering the validation pipeline.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Opus.Trading.Granularity

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "strategy_configs" do
    field(:source, :string, default: "ollama")
    field(:instrument, :string)
    field(:granularity, :string)
    field(:strategy_type, :string)
    field(:parameters, :map)
    field(:parent_config_id, Ecto.UUID)
    field(:depth, :integer, default: 0)
    field(:generation_prompt, :string)
    field(:evo_generation, :integer)
    field(:lineage_id, Ecto.UUID)
    field(:score, :float)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:instrument, :granularity, :strategy_type, :parameters]
  @optional [
    :source,
    :parent_config_id,
    :depth,
    :generation_prompt,
    :evo_generation,
    :lineage_id,
    :score
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          source: String.t() | nil,
          instrument: String.t() | nil,
          granularity: String.t() | nil,
          strategy_type: String.t() | nil,
          parameters: map() | nil,
          parent_config_id: Ecto.UUID.t() | nil,
          depth: non_neg_integer() | nil,
          generation_prompt: String.t() | nil,
          evo_generation: non_neg_integer() | nil,
          lineage_id: Ecto.UUID.t() | nil,
          score: float() | nil
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, attrs) do
    config
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:source, ["ollama", "manual", "reseed", "evolution"])
    |> validate_inclusion(:granularity, Granularity.all())
  end
end
