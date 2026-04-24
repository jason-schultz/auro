# Auro

Personal trading platform built with Rust, Elixir, and Vue. Connects to OANDA's v20 API for forex, commodity, metal, and index paper trading. Runs backtests, deploys strategies live, and journals what happens.

This is a learning project — I'm using it to get deeper into Rust, Vue 3, Elixir/OTP, and to actually understand how trading systems work under the hood.

## Layout

The repo has three services:

- `auro_be/` — Rust backend (axum). Streams prices from OANDA, aggregates ticks into candles, runs the live strategy evaluator, exposes the REST + WebSocket API, and runs grid-search backtests.
- `auro_fe/` — Vue 3 frontend. Dashboard, markets, strategy editor, backtest browser.
- `opus/` — Elixir/Phoenix service. Currently runs the trade reconciler (a GenServer that reconciles our `live_trades` table against OANDA's open trades every 60s) and an Oban-scheduled evaluation worker. Will gradually take on more of the long-running trading orchestration.

## Tech Stack

- **Rust backend:** axum, tokio, sqlx, reqwest
- **Elixir service:** Phoenix 1.7, Ecto, Oban, Bandit, Req
- **Frontend:** Vue 3 (Composition API, TypeScript, Vite, Bun)
- **Database:** PostgreSQL (shared between services)
- **UI:** shadcn-vue + Tailwind CSS v4
- **Charts:** TradingView lightweight-charts
- **Broker API:** OANDA v20 (REST + streaming)

## What it does right now

- Streams live prices from OANDA across ~40 instruments (forex majors + crosses, commodities, metals, indices)
- Aggregates live ticks into 1-minute candles and persists them continuously
- Backfills 7 days of M1 candles on startup, plus on-demand historical backfill at any granularity
- Candlestick charts with multiple timeframes (1m, 5m, 15m, 1H, 4H, D)
- Account info panel (NAV, balance, margin, unrealized/realized P&L, open trades)
- **Backtesting:** grid search across parameter ranges for mean reversion, trend following, and grid strategies. Results stored in `backtest_runs` / `backtest_trades` and browsable in the UI with stats (return, Sharpe, drawdown, win rate, trade detail).
- **Live trading:** strategies can be enabled to actually place trades on the OANDA practice account. The live evaluator subscribes to the price stream, evaluates rules per candle close, and fires market orders with stop loss / take profit. Risk controls (max daily loss, max open positions) live in `trading_config`.
- **Deploy from backtest:** promote a backtest result into a live strategy with one API call.
- **Trade reconciliation (Opus):** when OANDA closes a trade server-side via SL/TP, the Elixir reconciler detects the mismatch and updates our DB with the exit price, P&L, and exit reason.

## What's coming

- Migrating the live trading orchestration (price stream, evaluator, order placement) from Rust into Opus to consolidate state in one supervised OTP tree
- Wealthsimple manual trade journal for tracking stock trades (`Journal.vue` is a stub today)
- Stock screener / opportunity alerts via FMP
- DigitalOcean deployment with Caddy in front

## Running it

You'll need Rust, Elixir 1.14+, Bun, and PostgreSQL (I run Postgres in Docker).

Create the database:
```
psql -U postgres -h localhost -c "CREATE DATABASE auro;"
```

Rust backend:
```
cd auro_be
cp .env_example .env  # fill in your OANDA credentials
cargo run
```

Elixir service (Opus):
```
cd opus
mix setup
mix phx.server
```

Frontend:
```
cd auro_fe
bun install
bun dev
```

The frontend runs on `localhost:5173` and proxies API/WebSocket requests to the Rust backend on `localhost:3000`. Opus runs on `localhost:4000`.

## Backtests

Run a sweep across instruments from the command line:
```
./scripts/run_backtests.sh -s mean_reversion -p 4
./scripts/run_backtests.sh -s trend_following -p 2 -c
./scripts/run_backtests.sh -i EUR_USD -s both
```

Or call the API directly — see `auro_be/src/api/backtest.rs`. Results show up under `/backtests` in the UI.

## .env

Rust backend (`auro_be/.env`):
```
DATABASE_URL=postgres://postgres:postgres@localhost:5432/auro
OANDA_API_KEY=your_key
OANDA_ACCOUNT_ID=your_account_id
OANDA_BASE_URL=https://api-fxpractice.oanda.com
OANDA_STREAM_URL=https://stream-fxpractice.oanda.com
FMP_API_KEY=
FMP_BASE_URL=
HOST=127.0.0.1
PORT=3000
```

Opus (`opus/.env`) needs the same OANDA credentials and `DATABASE_URL`.

Don't commit your `.env` files. They're in the `.gitignore`.
