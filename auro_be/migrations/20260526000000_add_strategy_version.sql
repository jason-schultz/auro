-- Tracks which version of a strategy's logic produced a given backtest row.
-- Existing rows are tagged 'v0' (pre-MR-rebuild). New rows from the MR v1
-- rebuild forward should write 'v1'. This lets us segregate old vs. new
-- backtest results when comparing strategy performance across rebuilds.

ALTER TABLE backtest_runs
    ADD COLUMN strategy_version VARCHAR(8) NOT NULL DEFAULT 'v0';

-- Drop default for future inserts so writes must be explicit about the version
-- they produced. Existing rows keep their 'v0' tag from the backfill above.
ALTER TABLE backtest_runs
    ALTER COLUMN strategy_version DROP DEFAULT;

CREATE INDEX idx_backtest_runs_strategy_version
    ON backtest_runs (strategy_type, strategy_version);
