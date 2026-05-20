defmodule Opus.Repo.Migrations.CreateLiveTablesForOpusReads do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:live_strategies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :strategy_type, :string, null: false
      add :instrument, :string, null: false
      add :granularity, :string, null: false
      add :parameters, :map, null: false
      add :enabled, :boolean, null: false, default: false
      add :max_position_size, :string, null: false, default: "1000"
      add :backtest_run_id, :binary_id
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create_if_not_exists table(:live_trades, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :live_strategy_id, references(:live_strategies, type: :binary_id)
      add :oanda_trade_id, :string
      add :instrument, :string
      add :direction, :string
      add :units, :string
      add :entry_price, :float
      add :exit_price, :float
      add :entry_time, :utc_datetime_usec
      add :exit_time, :utc_datetime_usec
      add :stop_loss_price, :float
      add :take_profit_price, :float
      add :pnl, :float
      add :pnl_percent, :float
      add :entry_reason, :text
      add :exit_reason, :text
      add :status, :string, null: false, default: "open"
      add :metadata, :map
      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create_if_not_exists index(:live_trades, [:live_strategy_id])
    create_if_not_exists index(:live_trades, [:status])
    create_if_not_exists index(:live_trades, [:instrument])
  end
end
