# Auro

Personal algorithmic trading platform built with Rust, Elixir, and Vue 3. Connects to OANDA's v20 API for paper trading across forex, metals, commodities, and indices. Runs grid-search backtests, promotes strategies to live, manages open trades, and uses a regime-aware rules engine to gate which strategies are allowed to fire.

This is a learning project — built to go deep on Rust, Elixir/OTP, Vue 3, and what it actually takes to build a trading system end to end.

## Architecture

Three services sharing a PostgreSQL database:

**`auro_be/` — Rust engine (port 3000)**
The fast compute layer. Streams live prices from OANDA across 42 instruments, aggregates ticks into M1/M15/H1/H4 candles in real time, persists candles to the database, runs the live strategy evaluator on every candle close, manages open trade stop-loss progression, and runs grid-search backtests. Exposes a REST API consumed by both the frontend and Opus.

**`opus/` — Elixir orchestration layer (port 4321)**
The brain. Manages regime detection and rules: polls the Rust engine's indicator endpoints every 5 minutes across all active instruments at M15/H1/H4, classifies market regime (trending / choppy / uncertain) per timeframe, applies a multi-timeframe policy to decide which strategy types are allowed to fire, persists those decisions to the `rules` table, and pushes them to Rust via HTTP. Also runs trade reconciliation (syncing OANDA-side SL/TP closures back to the database) and a scheduled evaluation backstop. Runs on the Oban job queue.

**`auro_fe/` — Vue 3 frontend (port 5173)**
Dashboard, live strategies, backtest browser, and trade journal views. Calls both Rust (live state, indicators, backtests) and Opus (new endpoints) via a Vite proxy.

## Tech Stack

- **Rust engine:** axum, tokio, sqlx, reqwest
- **Elixir service:** Phoenix 1.7 (API-only), Ecto, Oban, Req
- **Frontend:** Vue 3 (Composition API, TypeScript, Vite, Bun)
- **Database:** PostgreSQL (shared between Rust and Elixir, running in Docker)
- **UI:** shadcn-vue + Tailwind CSS v4
- **Charts:** TradingView lightweight-charts
- **Broker API:** OANDA v20 (REST + streaming)

## Current State

### Live Trading
- 42 instruments streaming live: forex majors/crosses, metals (XAU, XAG, XPT, XPD, XCU), energies (WTICO, BCO, NATGAS), commodities (CORN, WHEAT, SOYBN, SUGAR), and indices (UK100, US30, NAS100, SPX500, JP225, DE30, EU50, AU200)
- 21 active live strategies across trend-following and mean-reversion types
- 2 open trades, 50+ closed trades on the OANDA practice account
- **Trade management:** trend-following positions automatically progress through three states — Initial SL → Breakeven SL (triggered at +1.5%) → OANDA-native trailing stop (triggered at +4%). Mean-reversion positions rely on OANDA-side fixed SL/TP.
- Live positions table in the UI shows management state (Initial / Breakeven / Trailing), current stop price, and target

### Candle Data
- ~3.6M+ candles across all granularities and instruments
- M1: live-aggregated from tick stream, persisted continuously
- M15 / H1 / H4: live-aggregated and persisted on every slot boundary
- Full OHLC on all live candles (open = first tick, high/low tracked throughout, close = last tick)
- Startup prefill loads the last 200 candles per (instrument, granularity) pair into in-memory buffers

### Regime Detection & Rules Engine
- **RegimeDetector** (Opus GenServer): polls ADX + Bollinger bandwidth from Rust every 5 minutes for all active instruments at M15, H1, and H4. Classifies each as `:trending` (ADX ≥ 25), `:choppy` (ADX < 20), or `:uncertain`.
- **RulesEngine** (Opus GenServer): applies a multi-timeframe policy using H4 as anchor and H1 as confirmation. Classifies composite regime and maps it to per-strategy enable/disable decisions. Policy: trend-following runs when trending or uncertain; mean-reversion runs when choppy or uncertain. Persists decisions to the `rules` table and pushes them to Rust via `POST /api/rules`. Rust caches rules in memory and consults them before every trade entry.
- Fail-open: unknown or uncertain regimes default to enabled so a cold start doesn't accidentally disable everything.

### Backtesting
- ~134k backtest runs stored across all instruments and strategy types
- Grid search sweeps parameter ranges in parallel; results stored with full stats (Sharpe, max drawdown, win rate, avg win/loss, total return, trade count)
- Promote any backtest result to a live strategy with a single API call
- Walk-forward and Monte Carlo validation endpoints exist for pipeline use

### Strategy Pipeline
- Database schema in place for automated strategy evaluation: `strategy_configs`, `strategy_evaluations`, `validation_thresholds`
- Pipeline progression: backtest → walk-forward → Monte Carlo → live promotion
- Ollama client (`opus/lib/opus/downstream/ollama/`) wired for LLM-assisted strategy generation (deepseek-r1:7b)

## Running It

You'll need Rust, Elixir 1.14+, Bun, and PostgreSQL (Docker recommended).

Create the database:
```
psql -U postgres -h localhost -c "CREATE DATABASE auro;"
```

Rust engine:
```
cd auro_be
cp .env_example .env   # fill in your OANDA credentials
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

The frontend runs on `localhost:5173` and proxies API requests to the Rust engine (`localhost:3000`) and Opus (`localhost:4321`).

## Backtests

Run a grid-search sweep from the command line:
```
./scripts/run_backtests.sh -s mean_reversion -p 4
./scripts/run_backtests.sh -s trend_following -p 2 -c
./scripts/run_backtests.sh -i EUR_USD -s both
```

Results are browsable in the UI under `/backtests`.

## Environment Variables

Rust engine (`auro_be/.env`):
```
DATABASE_URL=postgres://postgres:postgres@localhost:5432/auro
OANDA_API_KEY=your_key
OANDA_ACCOUNT_ID=your_account_id
OANDA_BASE_URL=https://api-fxpractice.oanda.com
OANDA_STREAM_URL=https://stream-fxpractice.oanda.com
HOST=127.0.0.1
PORT=3000
```

Opus (`opus/.env`):
```
DATABASE_URL=postgres://postgres:postgres@localhost:5432/auro
OANDA_API_KEY=your_key
OANDA_ACCOUNT_ID=your_account_id
OANDA_BASE_URL=https://api-fxpractice.oanda.com
AURO_BASE_URL=http://localhost:3000
```

Don't commit `.env` files — they're in `.gitignore`.

## Frontend Table Contract

Shared datatable behavior for Backtests, Pipeline, and Strategies is governed by a freeze policy documented at `auro_fe/docs/datatable-freeze.md`. Table behavior updates should follow that policy and keep helpers, mount logic, and e2e tests aligned.

## Coming Soon

**High priority**
- **Live strategies UI overhaul** — candlestick chart with SL/TP lines drawn at current levels, rules engine state panel showing current regime and enabled/disabled reason per strategy. Remove the Markets view (superseded by the live strategy chart).
- **Trade journal enrichment** — capture regime classification and key indicator values at trade entry; track MAE/MFE throughout the trade lifecycle.
- **Dynamic position sizing** — replace fixed unit sizes with a risk-percentage formula (e.g. risk 1% of account equity per trade, size derived from entry-to-SL distance). Essential before trading real money.
- **Per-strategy drawdown circuit breaker** — auto-suspend a strategy after N consecutive losses or a rolling drawdown threshold is breached.
- **Sector regime detection** — Opus aggregates per-instrument regimes into a sector consensus signal (metals first). Useful for detecting when the whole commodity complex is trending vs. consolidating.
- **Pipeline realtime updates** — push pipeline stage transitions to the frontend via Phoenix Channels instead of requiring a manual page refresh.

**Medium priority**
- **Portfolio-level risk dashboard** — aggregate view of position sizing, open risk, sector concentration, and circuit breaker state across all active strategies.
- **Per-strategy trade management config** — move breakeven/trailing thresholds out of Rust constants and into the `live_strategies` table, configurable per strategy.
- **Automated strategy discovery** — complete the Ollama-driven pipeline: LLM generates a config → backtest → walk-forward → Monte Carlo → auto-promote to live if all gates pass.
- **Postgres NOTIFY/LISTEN** — replace cron-based evaluation backstop with event-driven triggers. RegimeDetector and RulesEngine become reactive to new candle events rather than polling on a fixed cadence.
- **Rename `auro_be/` to `forge/`** — the engine has grown into something more than a backend; the new name better reflects its role.
