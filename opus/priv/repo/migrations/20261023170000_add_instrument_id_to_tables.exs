defmodule Opus.Repo.Migrations.AddInstrumentIdToTables do
  use Ecto.Migration

  @moduledoc """
  Phase 2 of the security master: every table that stores an instrument as
  text gets `instrument_id`, backfilled from the master by matching the
  text against the vendor spellings.

  Reference tables with no live write path take the column as required
  now. The live-trading tables, Wealthsimple positions and `candles` take
  it nullable and are dual-written from this point; they are tightened once
  a check shows no nulls (phase 4). `candles` is only given the column here:
  its 24M rows are filled by the rebuild-and-swap migration (phase 3), which
  needs the Rust engine stopped.
  """

  @strict ~w(instrument_financing instrument_risk_params instrument_unit_caps backtest_runs strategies strategy_configs)a
  @lenient ~w(live_strategies live_trades signal_events)a

  def up do
    for table <- @strict do
      add_and_backfill(table, "instrument")
      execute("ALTER TABLE #{table} ALTER COLUMN instrument_id SET NOT NULL;")
    end

    for table <- @lenient do
      add_and_backfill(table, "instrument")
    end

    add_and_backfill(:wealthsimple_positions, "symbol")

    execute(
      "ALTER TABLE candles ADD COLUMN IF NOT EXISTS instrument_id BIGINT REFERENCES instruments(id);"
    )
  end

  def down do
    for table <- @strict ++ @lenient ++ [:wealthsimple_positions, :candles] do
      execute("ALTER TABLE #{table} DROP COLUMN IF EXISTS instrument_id;")
    end
  end

  defp add_and_backfill(table, text_column) do
    execute(
      "ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS instrument_id BIGINT REFERENCES instruments(id);"
    )

    execute("""
    UPDATE #{table} t
    SET instrument_id = i.id
    FROM instruments i
    WHERE t.instrument_id IS NULL
      AND (i.oanda_symbol = t.#{text_column}
           OR i.questrade_symbol = t.#{text_column}
           OR i.massive_ticker = t.#{text_column});
    """)

    execute("CREATE INDEX IF NOT EXISTS idx_#{table}_instrument_id ON #{table} (instrument_id);")
  end
end
