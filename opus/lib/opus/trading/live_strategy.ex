defmodule Opus.Trading.LiveStrategy do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "live_strategies" do
    field :strategy_type, :string
    field :instrument, :string
    field :granularity, :string
    field :parameters, :map
    field :enabled, :boolean
    field :max_position_size, :string

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
