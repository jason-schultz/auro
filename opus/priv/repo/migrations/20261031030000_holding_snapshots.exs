defmodule Opus.Repo.Migrations.HoldingSnapshots do
  use Ecto.Migration

  @moduledoc """
  Each trading day's close (`Opus.Accounts.SnapshotWorker`, after the 16:00
  New York re-price):

    * `holding_snapshots`: the hand-entered Wealthsimple holdings, one row
      per holding a day, so their value has a history, a worst drop and a
      day's move to alert on;
    * `account_values`: every broker account's value (the Accounts page's
      overview), one row per account a day, so net worth has a line.
  """

  def change do
    create table(:holding_snapshots) do
      add :on, :date, null: false
      add :account_type, :string, null: false
      add :symbol, :string, null: false
      add :shares, :float, null: false
      add :avg_cost, :float
      add :price, :float, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:holding_snapshots, [:on, :account_type, :symbol])

    create table(:account_values) do
      add :on, :date, null: false
      add :broker, :string, null: false
      # The Accounts page's key for it: broker and account id.
      add :account, :string, null: false
      add :label, :string, null: false
      add :currency, :string, null: false
      add :value, :float, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:account_values, [:on, :account])
  end
end
