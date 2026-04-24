# Auro TODO

## Bugs / Refinements
- [ ] Real-time candle update overwrites OHLC — should only update close and extend high/low
- [ ] Price panel order jumps around — add consistent sorting (alphabetical or by category)
- [ ] Bid prices flash red on every tick — debounce or only flash on meaningful price changes

## Phase 1 — Core Trading
- [ ] Store 1-minute OHLCV candles to Postgres (candles table already exists)
- [ ] Backfill historical candle data from OANDA on startup
- [ ] Account info panel in the frontend

## Phase 2 — Strategy Engine
- [ ] Configurable rules engine (JSON/TOML strategy definitions)
- [ ] Strategy editor in Vue UI
- [ ] Backtesting against stored candle data

## Phase 3 — Wealthsimple
- [ ] Manual trade journal
- [ ] Stock screener / opportunity alerts

## Phase 4 — Deployment
- [ ] Move to DigitalOcean
- [ ] Postgres migration (already using Postgres)
- [ ] Reverse proxy setup (Caddy/nginx)
