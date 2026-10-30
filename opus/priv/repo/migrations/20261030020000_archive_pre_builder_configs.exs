defmodule Opus.Repo.Migrations.ArchivePreBuilderConfigs do
  use Ecto.Migration

  @moduledoc """
  Marks the strategy configs tried before the block builder as archive
  (`strategy_configs.archived_at`). Archived configs still count as tries
  for the deflated Sharpe; the strategy pages and the pipeline list hide
  them unless asked, and a live strategy's own results always show.

  The cut-off is the builder's first saved config. The builder landed in
  commit afcccef (2026-10-28 03:49 UTC); the recipes table was filled from
  the live strategies at 2026-10-28 01:30:26 UTC, and the first recipe
  saved from the builder ("shop_test", SHOP M5) was created at 02:59:37.846
  UTC with its test config at 02:59:37.862 UTC. Everything before that is
  archive: all 900 `evolution` configs (May 29–30) and the 630 `manual`
  ones (seed scripts, the June editor and the Oct 13/17 submissions).
  """

  @cutoff "2026-10-28 02:59:37.862436"

  def up do
    alter table(:strategy_configs) do
      add(:archived_at, :utc_datetime_usec)
    end

    flush()

    execute("""
    UPDATE strategy_configs SET archived_at = now()
    WHERE source = 'evolution' OR inserted_at < '#{@cutoff}'
    """)
  end

  def down do
    alter table(:strategy_configs) do
      remove(:archived_at)
    end
  end
end
