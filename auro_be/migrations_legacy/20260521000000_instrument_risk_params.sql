CREATE TABLE instrument_risk_params (
    instrument         VARCHAR(20)       NOT NULL,
    strategy_type      VARCHAR(50)       NOT NULL,
    trailing_k         DOUBLE PRECISION  NOT NULL,
    atr_period         INTEGER           NOT NULL DEFAULT 14,
    atr_granularity    VARCHAR(5)        NOT NULL DEFAULT 'H1',
    exit_confirm_bars  INTEGER           NOT NULL DEFAULT 3,
    created_at         TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    updated_at         TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    PRIMARY KEY (instrument, strategy_type)
);

COMMENT ON COLUMN instrument_risk_params.trailing_k IS
  'Multiplier applied to ATR for trailing-stop distance. Typical: 2.5-3.0 for trend_following, 1.0-1.5 for mean_reversion.';
COMMENT ON COLUMN instrument_risk_params.exit_confirm_bars IS
  'Consecutive bars at strategy granularity required for TrendReversal MA-cross to fire. Filters noise.';

INSERT INTO instrument_risk_params (
    instrument,
    strategy_type,
    trailing_k,
    atr_period,
    atr_granularity,
    exit_confirm_bars
)
SELECT DISTINCT
    ls.instrument,
    ls.strategy_type,
    CASE ls.strategy_type
        WHEN 'trend_following' THEN 2.5
        WHEN 'mean_reversion' THEN 1.2
        ELSE 2.0
    END AS trailing_k,
    14 AS atr_period,
    'H1' AS atr_granularity,
    3 AS exit_confirm_bars
FROM live_strategies ls
WHERE ls.strategy_type = 'trend_following'
ON CONFLICT (instrument, strategy_type) DO NOTHING;
