-- Active strategy configurations (what's actually running)
CREATE TABLE live_strategies (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    strategy_type VARCHAR(50) NOT NULL,
    instrument VARCHAR(20) NOT NULL,
    granularity VARCHAR(5) NOT NULL,
    parameters JSONB NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT false,
    max_position_size VARCHAR(20) NOT NULL DEFAULT '1000',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Live trade log
CREATE TABLE live_trades (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    live_strategy_id UUID REFERENCES live_strategies(id),
    oanda_trade_id VARCHAR(50),
    instrument VARCHAR(20) NOT NULL,
    direction VARCHAR(10) NOT NULL,
    units VARCHAR(20) NOT NULL,
    entry_price DOUBLE PRECISION,
    exit_price DOUBLE PRECISION,
    entry_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    exit_time TIMESTAMPTZ,
    stop_loss_price DOUBLE PRECISION,
    take_profit_price DOUBLE PRECISION,
    pnl DOUBLE PRECISION,
    pnl_percent DOUBLE PRECISION,
    entry_reason TEXT,
    exit_reason TEXT,
    status VARCHAR(20) NOT NULL DEFAULT 'open',
    metadata JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_live_trades_strategy ON live_trades (live_strategy_id);
CREATE INDEX idx_live_trades_status ON live_trades (status);
CREATE INDEX idx_live_trades_instrument ON live_trades (instrument);

-- Trading state and risk controls
CREATE TABLE trading_config (
    key VARCHAR(50) PRIMARY KEY,
    value JSONB NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Insert default risk controls
INSERT INTO trading_config (key, value) VALUES
    ('trading_enabled', '"true"'),
    ('max_daily_loss', '"-500.0"'),
    ('max_open_positions', '"5"'),
    ('max_position_size_default', '"1000"');

ALTER TABLE live_strategies ADD COLUMN backtest_run_id UUID REFERENCES backtest_runs(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX uq_live_strategies_instrument_type_params ON live_strategies (instrument, strategy_type, parameters);
