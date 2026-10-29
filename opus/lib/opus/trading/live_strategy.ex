defmodule Opus.Trading.LiveStrategy do
  @moduledoc """
  A recipe (`Opus.Trading.Recipe`) assigned to one instrument, with its
  sizing and what a signal does (`action`). Until the writers move to Opus,
  `parameters` is what gets written and a database trigger links the recipe
  and copies the sizing from it.
  """

  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "live_strategies" do
    field :strategy_type, :string
    field :instrument, :string
    field :instrument_id, :integer
    field :granularity, :string
    field :parameters, :map
    field :enabled, :boolean
    field :curator_mode, :string, default: "auto"
    field :sizing, :map
    field :action, :map, default: %{"type" => "oanda"}
    field :circuit_breaker_exempt, :boolean, default: false
    belongs_to :recipe, Opus.Trading.Recipe, foreign_key: :strategy_id, type: Ecto.UUID

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
