defmodule Opus.Repo.Migrations.CreateOptionTables do
  use Ecto.Migration

  # Listed US option contracts and their daily bars, from Massive via Rust
  # (POST /api/massive/options/...). Kept apart from `candles`: contracts
  # expire, the row count runs to millions, and the OCC ticker
  # (`O:SPY261219C00650000`) does not fit `candles.instrument`.
  def change do
    create_if_not_exists table(:option_contracts, primary_key: false) do
      add(:ticker, :string, size: 32, primary_key: true)
      add(:underlying, :string, size: 16, null: false)
      # "call" | "put"
      add(:contract_type, :string, size: 4, null: false)
      add(:expiration_date, :date, null: false)
      add(:strike, :float, null: false)
      add(:shares_per_contract, :integer, null: false, default: 100)
      # "american" | "european" | "bermudan"
      add(:exercise_style, :string, size: 10)
      add(:primary_exchange, :string, size: 8)
      add(:first_seen_at, :utc_datetime_usec, null: false)
      add(:last_seen_at, :utc_datetime_usec, null: false)
    end

    create_if_not_exists(index(:option_contracts, [:underlying, :expiration_date]))

    create_if_not_exists table(:option_bars, primary_key: false) do
      add(:ticker, :string, size: 32, null: false, primary_key: true)
      # Bar open, midnight New York for daily bars (Massive convention).
      add(:timestamp, :utc_datetime_usec, null: false, primary_key: true)
      add(:open, :float, null: false)
      add(:high, :float, null: false)
      add(:low, :float, null: false)
      add(:close, :float, null: false)
      add(:volume, :integer, null: false, default: 0)
      add(:transactions, :integer)
      add(:created_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    # "the chain on a date" = option_bars by timestamp joined to contracts.
    create_if_not_exists(index(:option_bars, [:timestamp]))
  end
end
