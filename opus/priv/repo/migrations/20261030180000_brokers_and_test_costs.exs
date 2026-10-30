defmodule Opus.Repo.Migrations.BrokersAndTestCosts do
  use Ecto.Migration

  @moduledoc """
  Each market is tested with the costs of the broker it's meant to trade
  on, not OANDA's by default.

  `brokers`: one row per broker and the costs its tests charge.
  - `overnight_cost`: `oanda_financing` (OANDA's daily financing, the
    engine's model) or `none` (a cash account holds shares for free).
  - `spread_bps`: the round-trip spread charged per trade in basis points
    when the bars carry no bid/ask; NULL means fill at the bars' bid/ask
    (OANDA's do). A market's own `instruments.spread_bps` overrides it.
  - `commission_bps`: charged on entry and again on exit.
  - `can_short`: when false, a strategy's short rules are skipped in its
    tests (and the result says so).

  `instruments.test_broker`: the broker a market's tests assume. A market
  without one is not tested. OANDA markets get `oanda`; US/Canadian stocks
  and ETFs get `wealthsimple` (traded by hand there, CAD converted to USD
  once, so no per-trade conversion fee). Wealthsimple's 10 bp default
  spread is deliberately on the high side for big ETFs until each market's
  own is measured into `instruments.spread_bps`.
  """

  def up do
    create table(:brokers, primary_key: false) do
      add :name, :string, size: 20, primary_key: true
      add :label, :string, size: 40, null: false
      add :overnight_cost, :string, size: 20, null: false
      add :spread_bps, :float
      add :commission_bps, :float, null: false, default: 0.0
      add :can_short, :boolean, null: false
      timestamps(type: :utc_datetime)
    end

    create constraint(:brokers, :overnight_cost_known,
             check: "overnight_cost IN ('oanda_financing', 'none')"
           )

    execute """
    INSERT INTO brokers (name, label, overnight_cost, spread_bps, commission_bps, can_short,
                         inserted_at, updated_at)
    VALUES ('oanda', 'OANDA', 'oanda_financing', NULL, 0, TRUE, now(), now()),
           ('wealthsimple', 'Wealthsimple', 'none', 10, 0, FALSE, now(), now())
    """

    alter table(:instruments) do
      add :test_broker, references(:brokers, column: :name, type: :string, on_delete: :nothing)
      add :spread_bps, :float
    end

    execute "UPDATE instruments SET test_broker = 'oanda' WHERE oanda_symbol IS NOT NULL"

    execute """
    UPDATE instruments SET test_broker = 'wealthsimple'
    WHERE oanda_symbol IS NULL AND asset_class IN ('etf', 'equity')
    """
  end

  def down do
    alter table(:instruments) do
      remove :spread_bps
      remove :test_broker
    end

    drop table(:brokers)
  end
end
