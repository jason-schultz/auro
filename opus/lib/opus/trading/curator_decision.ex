defmodule Opus.Trading.CuratorDecision do
  use Ecto.Schema
  import Ecto.Changeset

  schema "curator_decisions" do
    field :live_strategy_id, Ecto.UUID
    field :action, :string
    field :reason, :string
    field :rules_window, :map
    field :decided_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [:live_strategy_id, :action, :reason, :rules_window, :decided_at])
    |> validate_required([:live_strategy_id, :action, :reason, :rules_window, :decided_at])
  end
end
