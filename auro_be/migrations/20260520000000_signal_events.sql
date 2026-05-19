CREATE TABLE IF NOT EXISTS signal_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    strategy_id UUID NOT NULL,
    strategy_type VARCHAR(50) NOT NULL,
    instrument VARCHAR(20) NOT NULL,
    granularity VARCHAR(5) NOT NULL,
    action VARCHAR(40) NOT NULL,
    price DOUBLE PRECISION NOT NULL,
    reason TEXT NOT NULL,
    oanda_trade_id VARCHAR(50),
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_signal_events_timestamp_desc
    ON signal_events (timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_signal_events_instrument_time
    ON signal_events (instrument, timestamp DESC);
