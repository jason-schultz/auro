defmodule Opus.Pipeline.StrategyConfig do
  @moduledoc """
  Ecto schema for a hand-specified strategy config entering the validation
  pipeline (backtest → walk-forward → Monte Carlo → holdout).

  The table still carries the retired breeder's columns (`parent_config_id`,
  `depth`, `generation_prompt`, `evo_generation`, `lineage_id`, `score`) for
  historical rows; they are no longer read or written.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Opus.Instruments
  alias Opus.Instruments.Instrument
  alias Opus.Trading.Granularity

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "strategy_configs" do
    field(:source, :string, default: "manual")
    field(:instrument, :string)
    field(:granularity, :string)
    field(:strategy_type, :string)
    field(:parameters, :map)
    belongs_to(:instrument_ref, Instrument, foreign_key: :instrument_id, type: :id)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:instrument, :granularity, :strategy_type, :parameters]
  @optional [:source]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          source: String.t() | nil,
          instrument: String.t() | nil,
          instrument_id: integer() | nil,
          granularity: String.t() | nil,
          strategy_type: String.t() | nil,
          parameters: map() | nil
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, attrs) do
    config
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:source, ["manual"])
    |> validate_inclusion(:granularity, Granularity.all())
    |> put_instrument_id()
  end

  # The config is keyed on the master; an instrument nobody has added
  # cannot enter the pipeline.
  defp put_instrument_id(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp put_instrument_id(changeset) do
    case changeset |> get_field(:instrument) |> Instruments.id_for() do
      {:ok, id} -> put_change(changeset, :instrument_id, id)
      :error -> add_error(changeset, :instrument, "is not in the instruments table")
    end
  end
end
