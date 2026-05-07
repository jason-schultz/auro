defmodule Opus.Repo.Migrations.CreateRulesTable do
  use Ecto.Migration

  @doc """
  Per Decision Log #23: Opus persists rules to this table AND pushes the same
  payload to Rust via HTTP. The DB row is the persistence + recovery path; the
  HTTP push is the activation path.

  Per Database Migration Ownership: Opus owns this table because Opus writes to
  it. Rust reads from it on startup for recovery (reads only, no migrations).

  No FK to live_strategies because that table is in Rust's migration domain.
  Orphaned rows (rules for deleted strategies) are harmless — Rust ignores
  unknown strategy_ids on lookup.
  """
  def change do
    create table(:rules, primary_key: false) do
      add :live_strategy_id, :binary_id, primary_key: true
      add :enabled, :boolean, null: false
      add :reason, :text
      add :computed_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
