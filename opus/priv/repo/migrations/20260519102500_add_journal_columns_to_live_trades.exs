defmodule Opus.Repo.Migrations.AddJournalColumnsToLiveTrades do
  use Ecto.Migration

  def change do
    alter table(:live_trades) do
      add_if_not_exists :mfe_pct, :float
      add_if_not_exists :mae_pct, :float
      add_if_not_exists :regime_at_entry, :string
      add_if_not_exists :pnl, :float
    end
  end
end
