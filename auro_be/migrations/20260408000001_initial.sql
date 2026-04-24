-- Enable useful extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Candle data storage (1-minute OHLCV)
CREATE TABLE candles (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    instrument VARCHAR(20) NOT NULL,
    granularity VARCHAR(5) NOT NULL DEFAULT 'M1',
    timestamp TIMESTAMPTZ NOT NULL,
    open DOUBLE PRECISION NOT NULL,
    high DOUBLE PRECISION NOT NULL,
    low DOUBLE PRECISION NOT NULL,
    close DOUBLE PRECISION NOT NULL,
    volume INTEGER NOT NULL DEFAULT 0,
    complete BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (instrument, granularity, timestamp)
);

-- Index for time-range queries per instrument
CREATE INDEX idx_candles_instrument_time
    ON candles (instrument, granularity, timestamp DESC);
