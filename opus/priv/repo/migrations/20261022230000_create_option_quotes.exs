defmodule Opus.Repo.Migrations.CreateOptionQuotes do
  use Ecto.Migration

  # Nightly option chain snapshots from Questrade via Rust
  # (POST /api/questrade/options/snapshot): one row per contract per capture
  # with the Level 1 quote and the exchange greeks, as reported. Append-only;
  # the history a backtest needs is `option_bars`, this is what the chain
  # looked like each night going forward (and the spread the backtest must
  # pay).
  def change do
    create_if_not_exists table(:option_quotes, primary_key: false) do
      add(:ticker, :string, size: 32, null: false, primary_key: true)
      add(:captured_at, :utc_datetime_usec, null: false, primary_key: true)
      # "questrade" for now; a Massive snapshot would share the table.
      add(:source, :string, size: 16, null: false)
      # The underlying's price at the same capture.
      add(:spot, :float, null: false)
      add(:bid, :float)
      add(:ask, :float)
      add(:last, :float)
      add(:bid_size, :integer)
      add(:ask_size, :integer)
      add(:volume, :integer)
      add(:open_interest, :integer)
      # Implied volatility as the vendor reports it (Questrade: percent).
      add(:volatility, :float)
      add(:delta, :float)
      add(:gamma, :float)
      add(:theta, :float)
      add(:vega, :float)
      add(:rho, :float)
      # Vendor-reported quote delay; 0 = real-time.
      add(:delay_seconds, :integer)
    end

    # "the chain on a night" = option_quotes by captured_at joined to contracts.
    create_if_not_exists(index(:option_quotes, [:captured_at]))
  end
end
