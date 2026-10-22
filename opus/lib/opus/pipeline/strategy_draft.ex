defmodule Opus.Pipeline.StrategyDraft do
  @moduledoc """
  Work-in-progress strategy from the FE Strategy Editor.

  A draft is instrument-agnostic: `definition` holds the editor's component/
  wiring/risk state (the signal logic), while instrument and granularity are
  only remembered as the last preview context. Submitting a draft to the
  validation pipeline instantiates it against a concrete instrument +
  granularity as a `strategy_configs` row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "strategy_drafts" do
    field(:name, :string)
    field(:definition, :map)
    field(:last_instrument, :string)
    field(:last_granularity, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:name, :definition]
  @optional [:last_instrument, :last_granularity]

  def changeset(draft, attrs) do
    draft
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 120)
  end
end
