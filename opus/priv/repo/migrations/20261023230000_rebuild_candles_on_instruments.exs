defmodule Opus.Repo.Migrations.RebuildCandlesOnInstruments do
  use Ecto.Migration

  @moduledoc """
  Phase 3 of the security master: rebuild `candles` with `instrument_id`
  required and keyed by it.

  RUN WITH THE RUST ENGINE STOPPED. The whole rebuild is one transaction
  that holds an exclusive lock on `candles` for its duration (10–20 minutes
  for ~24M rows); Rust's candle feed would block on it and then time out.

  What changes:

    * `instrument_id` is NOT NULL and the primary key is
      `(instrument_id, granularity, timestamp)`.
    * The uuid `id` column is gone: nothing read it, and its index cost more
      than the table's natural key.
    * `idx_candles_instrument_time` is gone: it was the unique constraint's
      index again with `timestamp DESC`, and a btree serves either sort
      direction.
    * The text `instrument` column and its unique constraint stay, because
      the Rust upsert still conflicts on them; phase 4 drops them.
    * Rows are written in `(instrument_id, granularity, timestamp)` order so
      the history loads the backtester does are sequential reads.

  The old table is kept as `candles_legacy` until phase 4 verifies the
  rebuild; `down` swaps it back and drops the rebuilt table, losing any
  candles stored after the swap.
  """

  @legacy_renames [
    {"CONSTRAINT", "candles_pkey", "candles_legacy_pkey"},
    {"CONSTRAINT", "candles_instrument_granularity_timestamp_key",
     "candles_legacy_instrument_granularity_timestamp_key"},
    {"CONSTRAINT", "candles_instrument_id_fkey", "candles_legacy_instrument_id_fkey"}
  ]

  @columns ~w(
    instrument_id instrument granularity timestamp
    open high low close volume complete created_at
    bid_open bid_high bid_low bid_close
    ask_open ask_high ask_low ask_close
  )

  def up do
    execute("SET LOCAL maintenance_work_mem = '512MB';")
    execute("SET LOCAL work_mem = '256MB';")

    execute("ALTER TABLE candles RENAME TO candles_legacy;")

    for {kind, from, to} <- @legacy_renames do
      execute("ALTER TABLE candles_legacy RENAME #{kind} #{from} TO #{to};")
    end

    execute(
      "ALTER INDEX idx_candles_instrument_time RENAME TO idx_candles_legacy_instrument_time;"
    )

    execute("""
    CREATE TABLE candles (
      instrument_id BIGINT NOT NULL,
      instrument VARCHAR(20) NOT NULL,
      granularity VARCHAR(5) NOT NULL DEFAULT 'M1',
      timestamp TIMESTAMPTZ NOT NULL,
      open DOUBLE PRECISION NOT NULL,
      high DOUBLE PRECISION NOT NULL,
      low DOUBLE PRECISION NOT NULL,
      close DOUBLE PRECISION NOT NULL,
      volume INTEGER NOT NULL DEFAULT 0,
      complete BOOLEAN NOT NULL DEFAULT false,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      bid_open DOUBLE PRECISION,
      bid_high DOUBLE PRECISION,
      bid_low DOUBLE PRECISION,
      bid_close DOUBLE PRECISION,
      ask_open DOUBLE PRECISION,
      ask_high DOUBLE PRECISION,
      ask_low DOUBLE PRECISION,
      ask_close DOUBLE PRECISION
    );
    """)

    copied = Enum.map_join(tl(@columns), ", ", &"c.#{&1}")

    execute("""
    INSERT INTO candles (#{Enum.join(@columns, ", ")})
    SELECT n.id, #{copied}
    FROM candles_legacy c
    JOIN (
      SELECT oanda_symbol AS name, id FROM instruments WHERE oanda_symbol IS NOT NULL
      UNION
      SELECT questrade_symbol, id FROM instruments WHERE questrade_symbol IS NOT NULL
      UNION
      SELECT massive_ticker, id FROM instruments WHERE massive_ticker IS NOT NULL
    ) n ON n.name = c.instrument
    ORDER BY n.id, c.granularity, c.timestamp;
    """)

    # A candle whose instrument is not in the master has no id to carry; the
    # join above would drop it silently, so refuse the whole rebuild instead.
    execute("""
    DO $$
    DECLARE legacy BIGINT; rebuilt BIGINT;
    BEGIN
      SELECT count(*) INTO legacy FROM candles_legacy;
      SELECT count(*) INTO rebuilt FROM candles;
      IF legacy <> rebuilt THEN
        RAISE EXCEPTION 'candles rebuild copied % of % rows: % instruments are missing from the master (%)',
          rebuilt, legacy,
          (SELECT count(DISTINCT instrument) FROM candles_legacy l
            WHERE NOT EXISTS (SELECT 1 FROM instruments i
                              WHERE i.oanda_symbol = l.instrument
                                 OR i.questrade_symbol = l.instrument
                                 OR i.massive_ticker = l.instrument)),
          (SELECT string_agg(DISTINCT l.instrument, ', ') FROM candles_legacy l
            WHERE NOT EXISTS (SELECT 1 FROM instruments i
                              WHERE i.oanda_symbol = l.instrument
                                 OR i.questrade_symbol = l.instrument
                                 OR i.massive_ticker = l.instrument));
      END IF;
    END $$;
    """)

    execute(
      "ALTER TABLE candles ADD CONSTRAINT candles_pkey PRIMARY KEY (instrument_id, granularity, timestamp);"
    )

    execute(
      "ALTER TABLE candles ADD CONSTRAINT candles_instrument_granularity_timestamp_key UNIQUE (instrument, granularity, timestamp);"
    )

    execute(
      "ALTER TABLE candles ADD CONSTRAINT candles_instrument_id_fkey FOREIGN KEY (instrument_id) REFERENCES instruments(id);"
    )

    execute("ANALYZE candles;")
  end

  def down do
    execute("DROP TABLE candles;")
    execute("ALTER TABLE candles_legacy RENAME TO candles;")

    for {kind, from, to} <- @legacy_renames do
      execute("ALTER TABLE candles RENAME #{kind} #{to} TO #{from};")
    end

    execute(
      "ALTER INDEX idx_candles_legacy_instrument_time RENAME TO idx_candles_instrument_time;"
    )
  end
end
