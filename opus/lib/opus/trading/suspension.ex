defmodule Opus.Trading.Suspension do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "strategy_suspensions" do
    field :live_strategy_id, :binary_id
    field :triggered_at, :utc_datetime_usec
    field :trigger_kind, :string
    field :trigger_detail, :string
    field :cleared_at, :utc_datetime_usec
    field :cleared_by, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(suspension, attrs) do
    suspension
    |> cast(attrs, [
      :live_strategy_id,
      :triggered_at,
      :trigger_kind,
      :trigger_detail,
      :cleared_at,
      :cleared_by
    ])
    |> validate_required([:live_strategy_id, :triggered_at, :trigger_kind, :trigger_detail])
  end
end
