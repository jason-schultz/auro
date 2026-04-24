# Auro

Personal trading platform built with Rust and Vue. Connects to OANDA's v20 API for forex and commodities paper trading, with plans to eventually support algo trading strategies.

This is a learning project — I'm using it to get deeper into Rust, Vue 3, and to actually understand how trading systems work under the hood.

## Tech Stack

- **Backend:** Rust (axum, tokio, sqlx)
- **Frontend:** Vue 3 (Composition API, TypeScript, Vite, Bun)
- **Database:** PostgreSQL
- **UI:** shadcn-vue + Tailwind CSS
- **Charts:** TradingView lightweight-charts
- **Broker API:** OANDA v20 (REST + streaming)

## What it does right now

- Connects to OANDA practice account
- Streams live prices via WebSocket (EUR/USD, USD/CAD, GBP/USD, USD/JPY, AUD/USD, XAU/USD)
- Displays live bid/ask prices with spread
- Candlestick charts with multiple timeframes (1m, 5m, 15m, 1H, 4H, D)
- Backfills 7 days of 1-minute candle data to Postgres on startup
- Aggregates live ticks into 1-minute candles and stores them continuously
- Account info panel (balance, margin, P&L)
- Strategy CRUD API (frontend editor still in progress)

## What's coming

- Strategy rules engine — define entry/exit conditions, stop loss, take profit as config and have the backend evaluate them against live data
- Backtesting against stored candle data
- Wealthsimple manual trade journal for tracking stock trades
- Eventually moving to DigitalOcean with a proper deployment setup

## Running it

You'll need Rust, Bun, and PostgreSQL (I run Postgres in Docker).

Create the database:
```
psql -U postgres -h localhost -c "CREATE DATABASE auro;"
```

Backend:
```
cd auro_be
cp .env.example .env  # fill in your OANDA credentials
cargo run
```

Frontend:
```
cd auro_fe
bun install
bun dev
```

The frontend runs on `localhost:5173` and proxies API/WebSocket requests to the backend on `localhost:3000`.

## .env

```
DATABASE_URL=postgres://postgres:postgres@localhost:5432/auro
OANDA_API_KEY=your_key
OANDA_ACCOUNT_ID=your_account_id
OANDA_BASE_URL=https://api-fxpractice.oanda.com
OANDA_STREAM_URL=https://stream-fxpractice.oanda.com
HOST=127.0.0.1
PORT=3000
```

Don't commit your `.env`. It's in the `.gitignore`.
