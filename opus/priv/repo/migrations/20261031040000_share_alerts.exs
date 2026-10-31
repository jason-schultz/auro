defmodule Opus.Repo.Migrations.ShareAlerts do
  use Ecto.Migration

  @moduledoc """
  Share alerts (`Opus.Trading.ShareAlerts`): what a daily strategy assigned
  to a stock or ETF said 15 minutes before the close, one row per
  assignment a day, and what you did about it at Wealthsimple, logged by
  hand. The logged fills are the only record of what each assignment holds.
  """

  def change do
    create table(:share_alerts) do
      add :live_strategy_id, references(:live_strategies, type: :uuid, on_delete: :delete_all),
        null: false

      add :day, :date, null: false
      # buy | sell
      add :side, :string, null: false
      # A sell's reason: stop | time_stop | rule
      add :reason, :string
      # The Questrade ticker, as the holdings list it.
      add :symbol, :string, null: false
      add :currency, :string, null: false
      # The price the decision was made on and the stop to set (buys).
      add :price, :float, null: false
      add :stop_price, :float
      # Suggested: the amount over the price for a buy, the holding for a sell.
      add :shares, :float, null: false
      # open (waiting for your log) | filled | skipped
      add :status, :string, null: false, default: "open"
      add :filled_shares, :float
      add :filled_price, :float
      add :filled_at, :utc_datetime
      # The Wealthsimple account it was filled in (its type, e.g. TFSA).
      add :account, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:share_alerts, [:live_strategy_id, :day])
    create index(:share_alerts, [:status])
  end
end
