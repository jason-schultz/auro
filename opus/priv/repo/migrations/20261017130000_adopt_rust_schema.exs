defmodule Opus.Repo.Migrations.AdoptRustSchema do
  use Ecto.Migration

  @moduledoc """
  Opus now owns every migration. This is the Rust engine's schema as it stood
  on 2026-10-17 (auro_be/migrations_legacy, 19 sqlx migrations), rewritten as
  one idempotent step:

    * on the dev/prod database, where sqlx already applied all of it, every
      statement is a no-op (IF NOT EXISTS / ON CONFLICT DO NOTHING);
    * on a fresh or test database it creates the full schema, including the
      partial live_strategies/live_trades mirrors earlier Opus migrations made
      for the test database, which it completes column by column.

  One-off data migrations from the Rust history (the 2026-10-17 realignment
  delete of index daily candles, the instrument_risk_params seed) are not
  repeated. The policy_rates seed is, because a fresh database needs it.

  From here on, changes to Rust-owned tables are Ecto migrations in this
  directory; Rust only verifies at startup that the tables it needs exist
  (auro_be/src/db/schema_check.rs).
  """

  def up do
    execute("""
    CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
    """)

    execute("""
    -- candles (Rust: price history for every instrument/granularity)
        CREATE TABLE IF NOT EXISTS candles (
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
            bid_open DOUBLE PRECISION, bid_high DOUBLE PRECISION, bid_low DOUBLE PRECISION, bid_close DOUBLE PRECISION,
            ask_open DOUBLE PRECISION, ask_high DOUBLE PRECISION, ask_low DOUBLE PRECISION, ask_close DOUBLE PRECISION,
            UNIQUE (instrument, granularity, timestamp)
        );
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_candles_instrument_time ON candles (instrument, granularity, timestamp DESC);
    """)

    execute("""
    -- strategies (legacy flat-shape strategies, kept for history)
        CREATE TABLE IF NOT EXISTS strategies (
            id UUID PRIMARY KEY,
            name VARCHAR(100) NOT NULL,
            instrument VARCHAR(20) NOT NULL,
            granularity VARCHAR(5) NOT NULL,
            enabled BOOLEAN NOT NULL DEFAULT false,
            config JSONB NOT NULL DEFAULT '{}',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_strategies_instrument ON strategies (instrument);
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_strategies_enabled ON strategies (enabled);
    """)

    execute("""
    -- backtest_runs / backtest_trades
        CREATE TABLE IF NOT EXISTS backtest_runs (
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
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            strategy_version VARCHAR(8) NOT NULL
        );
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_backtest_runs_instrument ON backtest_runs (instrument);
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_backtest_runs_strategy ON backtest_runs (strategy_type);
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_backtest_runs_status ON backtest_runs (status);
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_backtest_runs_strategy_version ON backtest_runs (strategy_type, strategy_version);
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS backtest_trades (
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
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_backtest_trades_run ON backtest_trades (backtest_run_id);
    """)

    execute("""
    -- live_strategies / live_trades (may already exist in a partial mirror: add every later column)
        CREATE TABLE IF NOT EXISTS live_strategies (
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
    """)

    execute("""
    ALTER TABLE live_strategies
            ADD COLUMN IF NOT EXISTS backtest_run_id UUID REFERENCES backtest_runs(id) ON DELETE SET NULL,
            ADD COLUMN IF NOT EXISTS risk_pct DOUBLE PRECISION NOT NULL DEFAULT 0.0,
            ADD COLUMN IF NOT EXISTS max_units BIGINT NULL,
            ADD COLUMN IF NOT EXISTS curator_mode VARCHAR(16) NOT NULL DEFAULT 'auto';
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS uq_live_strategies_instrument_type_params ON live_strategies (instrument, strategy_type, parameters);
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS live_trades (
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
    """)

    execute("""
    ALTER TABLE live_trades
            ADD COLUMN IF NOT EXISTS indicators_at_entry JSONB,
            ADD COLUMN IF NOT EXISTS regime_at_entry VARCHAR(120),
            ADD COLUMN IF NOT EXISTS mae_pct DOUBLE PRECISION,
            ADD COLUMN IF NOT EXISTS mfe_pct DOUBLE PRECISION,
            ADD COLUMN IF NOT EXISTS stop_loss_state_at_close VARCHAR(20),
            ADD COLUMN IF NOT EXISTS sizing_metadata JSONB,
            ADD COLUMN IF NOT EXISTS signal_price DOUBLE PRECISION,
            ADD COLUMN IF NOT EXISTS expected_entry_price DOUBLE PRECISION,
            ADD COLUMN IF NOT EXISTS entry_spread DOUBLE PRECISION,
            ADD COLUMN IF NOT EXISTS expected_exit_price DOUBLE PRECISION,
            ADD COLUMN IF NOT EXISTS exit_spread DOUBLE PRECISION;
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_live_trades_strategy ON live_trades (live_strategy_id);
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_live_trades_status ON live_trades (status);
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_live_trades_instrument ON live_trades (instrument);
    """)

    execute("""
    -- trading_config (key/value risk controls + pipeline holdout date)
        CREATE TABLE IF NOT EXISTS trading_config (
            key VARCHAR(50) PRIMARY KEY,
            value JSONB NOT NULL,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
    """)

    execute("""
    INSERT INTO trading_config (key, value) VALUES
            ('trading_enabled', '"true"'),
            ('max_daily_loss', '"-500.0"'),
            ('max_open_positions', '"5"'),
            ('max_position_size_default', '"1000"'),
            ('pipeline_holdout_start', '"2025-10-17"')
        ON CONFLICT (key) DO NOTHING;
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS account_snapshots (
            id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
            timestamp TIMESTAMPTZ NOT NULL,
            nav DOUBLE PRECISION NOT NULL,
            balance DOUBLE PRECISION NOT NULL,
            unrealized_pl DOUBLE PRECISION NOT NULL,
            margin_used DOUBLE PRECISION NOT NULL,
            margin_available DOUBLE PRECISION NOT NULL,
            currency VARCHAR(10) NOT NULL,
            open_position_count INT NOT NULL DEFAULT 0,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_account_snapshots_timestamp ON account_snapshots (timestamp DESC);
    """)

    execute("""
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
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_signal_events_timestamp_desc ON signal_events (timestamp DESC);
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_signal_events_instrument_time ON signal_events (instrument, timestamp DESC);
    """)

    execute("""
    -- instrument_risk_params: final shape after Opus's 20260525160000 (granularity in the key)
        CREATE TABLE IF NOT EXISTS instrument_risk_params (
            instrument VARCHAR(20) NOT NULL,
            strategy_type VARCHAR(50) NOT NULL,
            trailing_k DOUBLE PRECISION NOT NULL,
            atr_period INTEGER NOT NULL DEFAULT 14,
            atr_granularity VARCHAR(5) NOT NULL DEFAULT 'H1',
            exit_confirm_bars INTEGER NOT NULL DEFAULT 3,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            granularity VARCHAR(5) NOT NULL,
            PRIMARY KEY (instrument, strategy_type, granularity)
        );
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS questrade_tokens (
            singleton BOOLEAN PRIMARY KEY DEFAULT TRUE,
            refresh_token TEXT NOT NULL,
            access_token TEXT,
            api_server TEXT,
            expires_at TIMESTAMPTZ,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT singleton_check CHECK (singleton = TRUE)
        );
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS wealthsimple_accounts (
            id SERIAL PRIMARY KEY,
            account_type TEXT NOT NULL,
            account_number TEXT,
            currency TEXT NOT NULL DEFAULT 'CAD',
            cash DOUBLE PRECISION,
            market_value DOUBLE PRECISION,
            total_equity DOUBLE PRECISION,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS wealthsimple_positions (
            id SERIAL PRIMARY KEY,
            account_id INTEGER NOT NULL REFERENCES wealthsimple_accounts(id) ON DELETE CASCADE,
            symbol TEXT NOT NULL,
            shares DOUBLE PRECISION NOT NULL,
            avg_cost DOUBLE PRECISION,
            current_price DOUBLE PRECISION,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
    """)

    execute("""
    -- financing (see Rust engine::financing)
        CREATE TABLE IF NOT EXISTS policy_rates (
            currency VARCHAR(3) NOT NULL,
            effective_date DATE NOT NULL,
            rate DOUBLE PRECISION NOT NULL,
            PRIMARY KEY (currency, effective_date)
        );
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS instrument_financing (
            instrument VARCHAR(20) NOT NULL,
            as_of DATE NOT NULL,
            long_rate DOUBLE PRECISION NOT NULL,
            short_rate DOUBLE PRECISION NOT NULL,
            recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (instrument, as_of)
        );
    """)

    execute("""
    INSERT INTO policy_rates (currency, effective_date, rate) VALUES
        ('AUD', '2016-01-04', 0.020000),
        ('AUD', '2016-05-04', 0.017500),
        ('AUD', '2016-08-03', 0.015000),
        ('AUD', '2019-06-05', 0.012500),
        ('AUD', '2019-07-03', 0.010000),
        ('AUD', '2019-10-02', 0.007500),
        ('AUD', '2020-03-04', 0.005000),
        ('AUD', '2020-03-20', 0.002500),
        ('AUD', '2020-11-04', 0.001000),
        ('AUD', '2022-05-04', 0.003500),
        ('AUD', '2022-06-08', 0.008500),
        ('AUD', '2022-07-06', 0.013500),
        ('AUD', '2022-08-03', 0.018500),
        ('AUD', '2022-09-07', 0.023500),
        ('AUD', '2022-10-05', 0.026000),
        ('AUD', '2022-11-02', 0.028500),
        ('AUD', '2022-12-07', 0.031000),
        ('AUD', '2023-02-08', 0.033500),
        ('AUD', '2023-03-08', 0.036000),
        ('AUD', '2023-05-03', 0.038500),
        ('AUD', '2023-06-07', 0.041000),
        ('AUD', '2023-11-08', 0.043500),
        ('AUD', '2025-02-19', 0.041000),
        ('AUD', '2025-05-21', 0.038500),
        ('AUD', '2025-08-13', 0.036000),
        ('AUD', '2026-02-04', 0.038500),
        ('AUD', '2026-03-18', 0.041000),
        ('AUD', '2026-05-06', 0.043500),
        ('AUD', '2026-09-30', 0.046000),
        ('CAD', '2016-01-01', 0.005000),
        ('CAD', '2017-07-12', 0.007500),
        ('CAD', '2017-09-06', 0.010000),
        ('CAD', '2018-01-17', 0.012500),
        ('CAD', '2018-07-11', 0.015000),
        ('CAD', '2018-10-24', 0.017500),
        ('CAD', '2020-03-04', 0.012500),
        ('CAD', '2020-03-16', 0.007500),
        ('CAD', '2020-03-27', 0.002500),
        ('CAD', '2022-03-03', 0.005000),
        ('CAD', '2022-04-14', 0.010000),
        ('CAD', '2022-06-02', 0.015000),
        ('CAD', '2022-07-14', 0.025000),
        ('CAD', '2022-09-08', 0.032500),
        ('CAD', '2022-10-27', 0.037500),
        ('CAD', '2022-12-08', 0.042500),
        ('CAD', '2023-01-26', 0.045000),
        ('CAD', '2023-06-08', 0.047500),
        ('CAD', '2023-07-13', 0.050000),
        ('CAD', '2024-06-06', 0.047500),
        ('CAD', '2024-07-25', 0.045000),
        ('CAD', '2024-09-05', 0.042500),
        ('CAD', '2024-10-24', 0.037500),
        ('CAD', '2024-12-12', 0.032500),
        ('CAD', '2025-01-30', 0.030000),
        ('CAD', '2025-03-13', 0.027500),
        ('CAD', '2025-09-18', 0.025000),
        ('CAD', '2025-10-30', 0.022500),
        ('CHF', '2016-01-01', -0.007500),
        ('CHF', '2022-06-17', -0.002500),
        ('CHF', '2022-09-23', 0.005000),
        ('CHF', '2022-12-16', 0.010000),
        ('CHF', '2023-03-24', 0.015000),
        ('CHF', '2023-06-23', 0.017500),
        ('CHF', '2024-03-22', 0.015000),
        ('CHF', '2024-06-21', 0.012500),
        ('CHF', '2024-09-27', 0.010000),
        ('CHF', '2024-12-13', 0.005000),
        ('CHF', '2025-03-21', 0.002500),
        ('CHF', '2025-06-20', 0.000000),
        ('GBP', '2016-01-04', 0.005000),
        ('GBP', '2016-08-04', 0.002500),
        ('GBP', '2017-11-02', 0.005000),
        ('GBP', '2018-08-02', 0.007500),
        ('GBP', '2020-03-11', 0.002500),
        ('GBP', '2020-03-19', 0.001000),
        ('GBP', '2021-12-16', 0.002500),
        ('GBP', '2022-02-03', 0.005000),
        ('GBP', '2022-03-17', 0.007500),
        ('GBP', '2022-05-05', 0.010000),
        ('GBP', '2022-06-16', 0.012500),
        ('GBP', '2022-08-04', 0.017500),
        ('GBP', '2022-09-22', 0.022500),
        ('GBP', '2022-11-03', 0.030000),
        ('GBP', '2022-12-15', 0.035000),
        ('GBP', '2023-02-02', 0.040000),
        ('GBP', '2023-03-23', 0.042500),
        ('GBP', '2023-05-11', 0.045000),
        ('GBP', '2023-06-22', 0.050000),
        ('GBP', '2023-08-03', 0.052500),
        ('GBP', '2024-08-01', 0.050000),
        ('GBP', '2024-11-07', 0.047500),
        ('GBP', '2025-02-06', 0.045000),
        ('GBP', '2025-05-08', 0.042500),
        ('GBP', '2025-08-07', 0.040000),
        ('GBP', '2025-12-18', 0.037500),
        ('HKD', '2016-01-04', 0.007500),
        ('HKD', '2016-12-15', 0.010000),
        ('HKD', '2017-03-16', 0.012500),
        ('HKD', '2017-06-15', 0.015000),
        ('HKD', '2017-12-14', 0.017500),
        ('HKD', '2018-03-22', 0.020000),
        ('HKD', '2018-06-14', 0.022500),
        ('HKD', '2018-09-27', 0.025000),
        ('HKD', '2018-12-20', 0.027500),
        ('HKD', '2019-08-01', 0.025000),
        ('HKD', '2019-09-19', 0.022500),
        ('HKD', '2019-10-31', 0.020000),
        ('HKD', '2019-11-18', 0.021300),
        ('HKD', '2019-11-19', 0.022300),
        ('HKD', '2019-11-20', 0.022400),
        ('HKD', '2019-11-21', 0.022600),
        ('HKD', '2019-11-22', 0.022100),
        ('HKD', '2019-11-25', 0.021200),
        ('HKD', '2019-11-26', 0.020300),
        ('HKD', '2019-11-27', 0.020000),
        ('HKD', '2019-12-19', 0.020700),
        ('HKD', '2019-12-20', 0.021400),
        ('HKD', '2019-12-23', 0.022100),
        ('HKD', '2019-12-24', 0.022400),
        ('HKD', '2019-12-27', 0.023500),
        ('HKD', '2019-12-30', 0.024300),
        ('HKD', '2019-12-31', 0.024900),
        ('HKD', '2020-01-02', 0.027300),
        ('HKD', '2020-01-03', 0.026800),
        ('HKD', '2020-01-06', 0.025500),
        ('HKD', '2020-01-07', 0.024100),
        ('HKD', '2020-01-08', 0.022800),
        ('HKD', '2020-01-09', 0.020000),
        ('HKD', '2020-03-04', 0.015000),
        ('HKD', '2020-03-16', 0.008600),
        ('HKD', '2020-03-17', 0.009100),
        ('HKD', '2020-03-18', 0.009800),
        ('HKD', '2020-03-19', 0.010800),
        ('HKD', '2020-03-20', 0.011900),
        ('HKD', '2020-03-23', 0.012600),
        ('HKD', '2020-03-24', 0.012900),
        ('HKD', '2020-03-25', 0.013300),
        ('HKD', '2020-03-26', 0.013900),
        ('HKD', '2020-03-27', 0.014600),
        ('HKD', '2020-03-30', 0.015700),
        ('HKD', '2020-03-31', 0.016500),
        ('HKD', '2020-04-01', 0.017200),
        ('HKD', '2020-04-02', 0.016300),
        ('HKD', '2020-04-03', 0.015600),
        ('HKD', '2020-04-06', 0.014800),
        ('HKD', '2020-04-07', 0.014000),
        ('HKD', '2020-04-08', 0.012900),
        ('HKD', '2020-04-14', 0.012600),
        ('HKD', '2020-04-15', 0.012300),
        ('HKD', '2020-04-16', 0.012100),
        ('HKD', '2020-04-17', 0.011900),
        ('HKD', '2020-04-20', 0.011800),
        ('HKD', '2020-04-21', 0.011900),
        ('HKD', '2020-04-22', 0.011800),
        ('HKD', '2020-04-23', 0.011900),
        ('HKD', '2020-04-24', 0.012000),
        ('HKD', '2020-04-27', 0.011900),
        ('HKD', '2020-04-28', 0.011600),
        ('HKD', '2020-04-29', 0.011100),
        ('HKD', '2020-05-04', 0.010300),
        ('HKD', '2020-05-05', 0.009400),
        ('HKD', '2020-05-06', 0.008200),
        ('HKD', '2020-05-07', 0.007100),
        ('HKD', '2020-05-08', 0.006200),
        ('HKD', '2020-05-11', 0.005600),
        ('HKD', '2020-05-12', 0.005000),
        ('HKD', '2020-05-27', 0.005100),
        ('HKD', '2020-05-28', 0.005600),
        ('HKD', '2020-05-29', 0.006200),
        ('HKD', '2020-06-02', 0.005900),
        ('HKD', '2020-06-03', 0.005700),
        ('HKD', '2020-06-04', 0.005500),
        ('HKD', '2020-06-05', 0.005100),
        ('HKD', '2020-06-08', 0.005000),
        ('HKD', '2022-03-17', 0.007500),
        ('HKD', '2022-05-05', 0.012500),
        ('HKD', '2022-06-16', 0.020000),
        ('HKD', '2022-07-28', 0.027500),
        ('HKD', '2022-09-22', 0.035000),
        ('HKD', '2022-11-03', 0.042500),
        ('HKD', '2022-12-06', 0.042800),
        ('HKD', '2022-12-07', 0.043400),
        ('HKD', '2022-12-08', 0.042500),
        ('HKD', '2022-12-15', 0.047500),
        ('HKD', '2023-02-02', 0.050000),
        ('HKD', '2023-03-23', 0.052500),
        ('HKD', '2023-05-04', 0.055000),
        ('HKD', '2023-07-27', 0.057500),
        ('HKD', '2024-09-19', 0.052500),
        ('HKD', '2024-11-08', 0.050000),
        ('HKD', '2024-12-19', 0.047500),
        ('HKD', '2025-09-18', 0.045000),
        ('HKD', '2025-10-30', 0.042500),
        ('HKD', '2025-12-11', 0.040000),
        ('HKD', '2026-09-17', 0.042500),
        ('JPY', '2016-09-21', -0.001000),
        ('JPY', '2024-03-21', 0.000500),
        ('JPY', '2024-08-01', 0.002500),
        ('JPY', '2025-01-27', 0.005000),
        ('JPY', '2025-12-22', 0.007500),
        ('JPY', '2026-06-17', 0.010000),
        ('JPY', '2026-09-24', 0.012500),
        ('MXN', '2016-01-01', 0.032500),
        ('MXN', '2016-02-17', 0.037500),
        ('MXN', '2016-06-30', 0.042500),
        ('MXN', '2016-09-29', 0.047500),
        ('MXN', '2016-11-17', 0.052500),
        ('MXN', '2016-12-15', 0.057500),
        ('MXN', '2017-02-09', 0.062500),
        ('MXN', '2017-03-30', 0.065000),
        ('MXN', '2017-05-18', 0.067500),
        ('MXN', '2017-06-22', 0.070000),
        ('MXN', '2017-12-14', 0.072500),
        ('MXN', '2018-02-08', 0.075000),
        ('MXN', '2018-06-21', 0.077500),
        ('MXN', '2018-11-15', 0.080000),
        ('MXN', '2018-12-20', 0.082500),
        ('MXN', '2019-08-15', 0.080000),
        ('MXN', '2019-09-26', 0.077500),
        ('MXN', '2019-11-14', 0.075000),
        ('MXN', '2019-12-19', 0.072500),
        ('MXN', '2020-02-13', 0.070000),
        ('MXN', '2020-03-20', 0.065000),
        ('MXN', '2020-04-21', 0.060000),
        ('MXN', '2020-05-14', 0.055000),
        ('MXN', '2020-06-25', 0.050000),
        ('MXN', '2020-08-14', 0.045000),
        ('MXN', '2020-09-25', 0.042500),
        ('MXN', '2021-02-12', 0.040000),
        ('MXN', '2021-06-25', 0.042500),
        ('MXN', '2021-08-13', 0.045000),
        ('MXN', '2021-10-01', 0.047500),
        ('MXN', '2021-11-12', 0.050000),
        ('MXN', '2021-12-17', 0.055000),
        ('MXN', '2022-02-11', 0.060000),
        ('MXN', '2022-03-25', 0.065000),
        ('MXN', '2022-05-13', 0.070000),
        ('MXN', '2022-06-24', 0.077500),
        ('MXN', '2022-08-12', 0.085000),
        ('MXN', '2022-09-30', 0.092500),
        ('MXN', '2022-11-11', 0.100000),
        ('MXN', '2022-12-16', 0.105000),
        ('MXN', '2023-02-10', 0.110000),
        ('MXN', '2023-03-31', 0.112500),
        ('MXN', '2024-03-22', 0.110000),
        ('MXN', '2024-08-09', 0.107500),
        ('MXN', '2024-09-27', 0.105000),
        ('MXN', '2024-11-15', 0.102500),
        ('MXN', '2024-12-20', 0.100000),
        ('MXN', '2025-02-07', 0.095000),
        ('MXN', '2025-03-28', 0.090000),
        ('MXN', '2025-05-16', 0.085000),
        ('MXN', '2025-06-27', 0.080000),
        ('MXN', '2025-08-08', 0.077500),
        ('MXN', '2025-09-26', 0.075000),
        ('MXN', '2025-11-07', 0.072500),
        ('MXN', '2025-12-19', 0.070000),
        ('MXN', '2026-03-27', 0.067500),
        ('MXN', '2026-05-08', 0.065000),
        ('NZD', '2016-01-01', 0.025000),
        ('NZD', '2016-03-10', 0.022500),
        ('NZD', '2016-08-11', 0.020000),
        ('NZD', '2016-11-10', 0.017500),
        ('NZD', '2019-05-09', 0.015000),
        ('NZD', '2019-08-08', 0.010000),
        ('NZD', '2020-03-17', 0.002500),
        ('NZD', '2021-10-07', 0.005000),
        ('NZD', '2021-11-25', 0.007500),
        ('NZD', '2022-02-24', 0.010000),
        ('NZD', '2022-04-14', 0.015000),
        ('NZD', '2022-05-26', 0.020000),
        ('NZD', '2022-07-14', 0.025000),
        ('NZD', '2022-08-18', 0.030000),
        ('NZD', '2022-10-06', 0.035000),
        ('NZD', '2022-11-24', 0.042500),
        ('NZD', '2023-02-23', 0.047500),
        ('NZD', '2023-04-06', 0.052500),
        ('NZD', '2023-05-25', 0.055000),
        ('NZD', '2024-08-15', 0.052500),
        ('NZD', '2024-10-10', 0.047500),
        ('NZD', '2024-11-28', 0.042500),
        ('NZD', '2025-02-20', 0.037500),
        ('NZD', '2025-04-10', 0.035000),
        ('NZD', '2025-05-29', 0.032500),
        ('NZD', '2025-08-21', 0.030000),
        ('NZD', '2025-10-09', 0.025000),
        ('NZD', '2025-11-27', 0.022500),
        ('NZD', '2026-07-09', 0.025000),
        ('NZD', '2026-09-03', 0.027500),
        ('USD', '2016-01-01', 0.003750),
        ('USD', '2016-12-15', 0.006250),
        ('USD', '2017-03-16', 0.008750),
        ('USD', '2017-06-15', 0.011250),
        ('USD', '2017-12-14', 0.013750),
        ('USD', '2018-03-22', 0.016250),
        ('USD', '2018-06-14', 0.018750),
        ('USD', '2018-09-27', 0.021250),
        ('USD', '2018-12-20', 0.023750),
        ('USD', '2019-08-01', 0.021250),
        ('USD', '2019-09-19', 0.018750),
        ('USD', '2019-10-31', 0.016250),
        ('USD', '2020-03-04', 0.011250),
        ('USD', '2020-03-16', 0.001250),
        ('USD', '2022-03-17', 0.003750),
        ('USD', '2022-05-05', 0.008750),
        ('USD', '2022-06-16', 0.016250),
        ('USD', '2022-07-28', 0.023750),
        ('USD', '2022-09-22', 0.031250),
        ('USD', '2022-11-03', 0.038750),
        ('USD', '2022-12-15', 0.043750),
        ('USD', '2023-02-02', 0.046250),
        ('USD', '2023-03-23', 0.048750),
        ('USD', '2023-05-04', 0.051250),
        ('USD', '2023-07-27', 0.053750),
        ('USD', '2024-09-19', 0.048750),
        ('USD', '2024-11-08', 0.046250),
        ('USD', '2024-12-19', 0.043750),
        ('USD', '2025-09-18', 0.041250),
        ('USD', '2025-10-30', 0.038750),
        ('USD', '2025-12-11', 0.036250),
        ('USD', '2026-09-17', 0.038750),
        ('EUR', '2016-01-01', 0.000500),
        ('EUR', '2016-03-16', 0.000000),
        ('EUR', '2022-07-27', 0.005000),
        ('EUR', '2022-09-14', 0.012500),
        ('EUR', '2022-11-02', 0.020000),
        ('EUR', '2022-12-21', 0.025000),
        ('EUR', '2023-02-08', 0.030000),
        ('EUR', '2023-03-22', 0.035000),
        ('EUR', '2023-05-10', 0.037500),
        ('EUR', '2023-06-21', 0.040000),
        ('EUR', '2023-08-02', 0.042500),
        ('EUR', '2023-09-20', 0.045000),
        ('EUR', '2024-06-12', 0.042500),
        ('EUR', '2024-09-18', 0.035000),
        ('EUR', '2024-10-23', 0.032500),
        ('EUR', '2024-12-18', 0.030000),
        ('EUR', '2025-02-05', 0.027500),
        ('EUR', '2025-03-12', 0.025000),
        ('EUR', '2025-04-23', 0.022500),
        ('EUR', '2025-06-11', 0.020000),
        ('EUR', '2026-06-17', 0.022500),
        ('EUR', '2026-09-16', 0.025000),
        ('ZAR', '2016-01-02', 0.062500),
        ('ZAR', '2016-01-29', 0.067500),
        ('ZAR', '2016-03-18', 0.070000),
        ('ZAR', '2017-07-21', 0.067500),
        ('ZAR', '2018-03-29', 0.065000),
        ('ZAR', '2018-11-23', 0.067500),
        ('ZAR', '2019-07-19', 0.065000),
        ('ZAR', '2020-01-17', 0.062500),
        ('ZAR', '2020-03-20', 0.052500),
        ('ZAR', '2020-04-15', 0.042500),
        ('ZAR', '2020-05-22', 0.037500),
        ('ZAR', '2020-07-24', 0.035000),
        ('ZAR', '2021-11-19', 0.037500),
        ('ZAR', '2022-01-28', 0.040000),
        ('ZAR', '2022-03-25', 0.042500),
        ('ZAR', '2022-05-20', 0.047500),
        ('ZAR', '2022-07-22', 0.055000),
        ('ZAR', '2022-09-23', 0.062500),
        ('ZAR', '2022-11-25', 0.070000),
        ('ZAR', '2023-01-27', 0.072500),
        ('ZAR', '2023-03-31', 0.077500),
        ('ZAR', '2023-05-26', 0.082500),
        ('ZAR', '2024-09-20', 0.080000),
        ('ZAR', '2024-11-22', 0.077500),
        ('ZAR', '2025-01-31', 0.075000),
        ('ZAR', '2025-05-30', 0.072500),
        ('ZAR', '2025-08-01', 0.070000),
        ('ZAR', '2025-11-21', 0.067500),
        ('ZAR', '2026-05-29', 0.070000),
        ('ZAR', '2026-09-25', 0.072500)
        ON CONFLICT (currency, effective_date) DO NOTHING;
    """)
  end

  def down do
    # The Rust engine's tables are the system's history; never drop them here.
    :ok
  end
end
