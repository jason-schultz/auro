defmodule Opus.Repo.Migrations.AddLiveTableTimestampDefaults do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE live_strategies ALTER COLUMN created_at SET DEFAULT NOW()")
    execute("ALTER TABLE live_strategies ALTER COLUMN updated_at SET DEFAULT NOW()")

    execute("ALTER TABLE live_trades ALTER COLUMN created_at SET DEFAULT NOW()")
    execute("ALTER TABLE live_trades ALTER COLUMN updated_at SET DEFAULT NOW()")
  end

  def down do
    execute("ALTER TABLE live_strategies ALTER COLUMN created_at DROP DEFAULT")
    execute("ALTER TABLE live_strategies ALTER COLUMN updated_at DROP DEFAULT")

    execute("ALTER TABLE live_trades ALTER COLUMN created_at DROP DEFAULT")
    execute("ALTER TABLE live_trades ALTER COLUMN updated_at DROP DEFAULT")
  end
end
