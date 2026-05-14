defmodule Opus.Repo.Migrations.EnrichLiveTradesJournal do
  use Ecto.Migration

  def change do
    alter table(:live_trades) do
      add :indicators_at_entry, :map
      add :regime_at_entry, :string, size: 120
      add :mae_pct, :float
      add :mfe_pct, :float
      add :stop_loss_state_at_close, :string, size: 20
    end
  end
end
