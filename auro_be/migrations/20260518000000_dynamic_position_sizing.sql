ALTER TABLE live_strategies
  ADD COLUMN risk_pct DOUBLE PRECISION NOT NULL DEFAULT 0.0,
  ADD COLUMN max_units BIGINT NULL;

ALTER TABLE live_trades
  ADD COLUMN sizing_metadata JSONB NULL;

COMMENT ON COLUMN live_strategies.risk_pct IS
  'Fraction of NAV to risk per trade (0.01 = 1%). When 0, use static units field.';
COMMENT ON COLUMN live_strategies.max_units IS
  'Optional per-strategy absolute cap on units. NULL = no cap.';
COMMENT ON COLUMN live_trades.sizing_metadata IS
  'JSONB snapshot of the sizing decision at entry. See SizingMetadata struct in engine/live/sizing.rs.';
