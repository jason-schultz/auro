defmodule Opus.Repo.Migrations.CreateStrategySuspensions do
  use Ecto.Migration

  def change do
    create table(:strategy_suspensions) do
      add :live_strategy_id, :binary_id, null: false
      add :triggered_at, :utc_datetime_usec, null: false
      add :trigger_kind, :string, null: false
      add :trigger_detail, :text, null: false
      add :cleared_at, :utc_datetime_usec
      add :cleared_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      """
      CREATE INDEX strategy_suspensions_active_idx
      ON strategy_suspensions (live_strategy_id)
      WHERE cleared_at IS NULL
      """,
      "DROP INDEX strategy_suspensions_active_idx"
    )
  end
end
