defmodule Opus.Repo.Migrations.CreateCuratorDecisions do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS trading_config (
      key VARCHAR(50) PRIMARY KEY,
      value JSONB NOT NULL,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    INSERT INTO trading_config (key, value, updated_at)
    VALUES ('curator_enabled', 'false'::jsonb, NOW())
    ON CONFLICT (key) DO NOTHING
    """)

    create_if_not_exists table(:curator_decisions) do
      add :live_strategy_id,
          references(:live_strategies, type: :binary_id, on_delete: :delete_all),
          null: false

      add :action, :string, size: 16, null: false
      add :reason, :string, null: false
      add :rules_window, :map, null: false
      add :decided_at, :utc_datetime_usec, null: false, default: fragment("NOW()")

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create_if_not_exists index(:curator_decisions, [:live_strategy_id, :decided_at])
  end

  def down do
    drop_if_exists index(:curator_decisions, [:live_strategy_id, :decided_at])
    drop_if_exists table(:curator_decisions)

    execute("DELETE FROM trading_config WHERE key = 'curator_enabled'")
  end
end
