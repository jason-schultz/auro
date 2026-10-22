defmodule Opus.Trading.LiveTrade do
  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "live_trades" do
    field :live_strategy_id, Ecto.UUID
    field :instrument, :string
    field :pnl, :float
    field :mfe_pct, :float
    field :mae_pct, :float
    field :regime_at_entry, :string
    field :status, :string
    field :pnl_percent, :float
    field :entry_time, :utc_datetime_usec
    field :exit_time, :utc_datetime_usec
    field :direction, :string
    field :entry_price, :float
    field :exit_price, :float
    field :exit_reason, :string
    # Execution quality (Rust writes these; see Opus.Trading.ExecutionQuality)
    field :signal_price, :float
    field :expected_entry_price, :float
    field :entry_spread, :float
    field :expected_exit_price, :float
    field :exit_spread, :float

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
