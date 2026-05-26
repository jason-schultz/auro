defmodule Opus.Repo.Migrations.AddCuratorModeToLiveStrategies do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE live_strategies
    ADD COLUMN IF NOT EXISTS curator_mode VARCHAR(16) NOT NULL DEFAULT 'auto'
    """)

    execute("""
    UPDATE live_strategies
    SET curator_mode = CASE WHEN enabled THEN 'pinned_on' ELSE 'auto' END
    WHERE curator_mode IS NULL OR curator_mode = 'auto'
    """)
  end

  def down do
    execute("""
    ALTER TABLE live_strategies
    DROP COLUMN IF EXISTS curator_mode
    """)
  end
end
