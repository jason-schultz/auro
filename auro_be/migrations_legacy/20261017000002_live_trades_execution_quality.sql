-- Execution quality: what the backtest assumed each fill would be, next to
-- what OANDA actually filled, so live slippage can be measured per strategy.
--   signal_price          mid close of the bar the decision was taken on
--   expected_entry_price  the backtest's fill for that bar (ask close for a
--                         long, bid close for a short)
--   entry_spread          ask − bid at that bar's close
--   expected_exit_price / exit_spread: the same for evaluator-driven exits;
--   NULL when OANDA closed the trade itself (stop loss), since no bar-close
--   decision was involved.
ALTER TABLE live_trades
    ADD COLUMN IF NOT EXISTS signal_price DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS expected_entry_price DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS entry_spread DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS expected_exit_price DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS exit_spread DOUBLE PRECISION;
