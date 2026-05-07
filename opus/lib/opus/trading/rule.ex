defmodule Opus.Trading.Rule do
  @moduledoc """
  Persistence schema for the `rules` table. One row per `live_strategy_id`.

  Per Decision #23, this is the persistence side; the HTTP push to Rust is the
  activation side. RulesEngine writes here and then calls
  `Opus.Auro.Client.push_rules/1` to flush the result to Rust.

  Per the elixir skill: thin schema + changeset, business logic lives in
  `Opus.Trading.RulesEngine`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:live_strategy_id, Ecto.UUID, autogenerate: false}
  schema "rules" do
    field(:enabled, :boolean)
    field(:reason, :string)
    field(:computed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating or updating a rule. The primary key (live_strategy_id)
  must be present; everything else is part of the decision being recorded.
  """
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:live_strategy_id, :enabled, :reason, :computed_at])
    |> validate_required([:live_strategy_id, :enabled, :computed_at])
  end
end
