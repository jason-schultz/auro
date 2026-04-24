CREATE TABLE backtest_runs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    strategy_name VARCHAR(100) NOT NULL,
    strategy_type VARCHAR(50) NOT NULL,
    instrument VARCHAR(20) NOT NULL,
    granularity VARCHAR(5) NOT NULL DEFAULT 'M1',
    parameters JSONB NOT NULL,
    start_date TIMESTAMPTZ NOT NULL,
    end_date TIMESTAMPTZ NOT NULL,
    total_return DOUBLE PRECISION NOT NULL DEFAULT 0,
    win_rate DOUBLE PRECISION NOT NULL DEFAULT 0,
    sharpe_ratio DOUBLE PRECISION NOT NULL DEFAULT 0,
    max_drawdown DOUBLE PRECISION NOT NULL DEFAULT 0,
    num_trades INT NOT NULL DEFAULT 0,
    avg_win DOUBLE PRECISION NOT NULL DEFAULT 0,
    avg_loss DOUBLE PRECISION NOT NULL DEFAULT 0,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    reason_flagged TEXT,
    execution_duration_ms INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_backtest_runs_instrument ON backtest_runs (instrument);
CREATE INDEX idx_backtest_runs_strategy ON backtest_runs (strategy_type);
CREATE INDEX idx_backtest_runs_status ON backtest_runs (status);

CREATE TABLE backtest_trades (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    backtest_run_id UUID NOT NULL REFERENCES backtest_runs(id) ON DELETE CASCADE,
    entry_price DOUBLE PRECISION NOT NULL,
    exit_price DOUBLE PRECISION NOT NULL,
    entry_time TIMESTAMPTZ NOT NULL,
    exit_time TIMESTAMPTZ NOT NULL,
    pnl_percent DOUBLE PRECISION NOT NULL,
    entry_reason VARCHAR(50) NOT NULL,
    exit_reason VARCHAR(20) NOT NULL,
    entry_details JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_backtest_trades_run ON backtest_trades (backtest_run_id);