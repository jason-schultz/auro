defmodule Opus.Repo.Migrations.UpdateObanToV14 do
  use Ecto.Migration

  # Oban 2.24 requires schema version 14 (adds the queue-pause / meta columns
  # the newer plugins use). Down returns to the v12 schema from
  # 20260428214231_add_oban_jobs_table.
  def up, do: Oban.Migration.up(version: 14)
  def down, do: Oban.Migration.down(version: 12)
end
