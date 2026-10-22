ALTER TABLE live_trades
    ADD COLUMN IF NOT EXISTS indicators_at_entry  jsonb,
    ADD COLUMN IF NOT EXISTS regime_at_entry      varchar(120),
    ADD COLUMN IF NOT EXISTS mae_pct              double precision,
    ADD COLUMN IF NOT EXISTS mfe_pct              double precision,
    ADD COLUMN IF NOT EXISTS stop_loss_state_at_close varchar(20);
