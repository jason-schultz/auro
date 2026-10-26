defmodule Opus.Repo.Migrations.AddPaperOptionTrades do
  use Ecto.Migration

  @moduledoc """
  Multi-leg paper trades (research/options_paper_engine.md, v2). A trade
  groups the legs opened together (a spread's two, a condor's four, a single
  option's one) and belongs to one strategy's book. Legs gain a side, since
  the new books also buy options, and events carry their book so each book
  keeps its own cash. The wheel's existing legs become one trade each.
  """

  def up do
    create table(:paper_option_trades) do
      # wheel, put_spread, iron_condor, ideas, crash_puts
      add :strategy, :string, size: 16, null: false
      add :underlying_instrument_id, references(:instruments, type: :bigint), null: false
      # put, call, shares, put_spread, iron_condor
      add :structure, :string, size: 16, null: false
      add :opened_on, :date, null: false
      add :closed_on, :date
      # open, closed
      add :status, :string, size: 12, null: false, default: "open"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:paper_option_trades, [:strategy, :status])

    alter table(:paper_option_positions) do
      add :trade_id, references(:paper_option_trades, type: :bigint)
      # short or long; every wheel leg so far is short (a share lot is long
      # stock, but its P&L is read from its kind).
      add :side, :string, size: 5, null: false, default: "short"
    end

    alter table(:paper_option_events) do
      add :strategy, :string, size: 16, null: false, default: "wheel"
    end

    create index(:paper_option_events, [:strategy, :on])

    flush()

    execute("""
    INSERT INTO paper_option_trades
      (id, strategy, underlying_instrument_id, structure, opened_on, closed_on, status,
       inserted_at, updated_at)
    SELECT p.id, 'wheel', p.underlying_instrument_id, p.kind, p.opened_on, p.closed_on,
           CASE WHEN p.status = 'open' THEN 'open' ELSE 'closed' END, now(), now()
    FROM paper_option_positions p
    """)

    execute("UPDATE paper_option_positions SET trade_id = id")

    execute("""
    SELECT setval(pg_get_serial_sequence('paper_option_trades', 'id'),
                  GREATEST((SELECT max(id) FROM paper_option_trades), 1))
    """)

    execute("ALTER TABLE paper_option_positions ALTER COLUMN trade_id SET NOT NULL")
  end

  def down do
    alter table(:paper_option_positions) do
      remove :trade_id
      remove :side
    end

    drop index(:paper_option_events, [:strategy, :on])

    alter table(:paper_option_events) do
      remove :strategy
    end

    drop table(:paper_option_trades)
  end
end
