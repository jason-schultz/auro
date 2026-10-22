-- Sealed holdout for the strategy pipeline. Bars from this date on are hidden
-- from the backtest, walk-forward and Monte Carlo stages; the holdout stage
-- alone sees them, once per config, as the last gate before promotion. Move
-- the date forward deliberately (and rarely): every candidate judged on a
-- window spends it. Stored as an ISO date string.
INSERT INTO trading_config (key, value) VALUES ('pipeline_holdout_start', '"2025-10-17"')
ON CONFLICT (key) DO NOTHING;
