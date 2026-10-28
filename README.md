# Auro

A personal algorithmic trading platform. Auro builds and tests trading strategies,
trades the ones that pass on an OANDA practice account, paper-trades options, and
tells you in plain words what happened and what (if anything) you need to do.

Real-money trades are placed by hand (on Wealthsimple); Auro does the research,
the testing, the forward-testing and the alerting.

> **Not financial advice.** Auro is experimental software. Backtests and paper
> results don't guarantee anything about real trading. Use it at your own risk.

## What it does

- **Strategy builder.** Build a strategy from signal blocks (RSI, moving averages,
  noise band, breakout channel, MACD, momentum and more), say when to buy, sell
  short and close, set the stop and hold limit, and see a preview of every buy
  and sell it would have made.
- **Testing.** Every strategy goes through the same pipeline before it can trade:
  backtest, walk-forward (data it wasn't fitted to), Monte Carlo (trades redrawn
  at random) and a sealed holdout. One standard applies to all of them, based on
  whether a result could be luck. Each rule is shown next to its result.
- **Strategies and instruments.** A strategy (the rules) is assigned to
  instruments (where it runs, at what size). A strategy that's trading is locked;
  to change it you edit a copy or switch it off first.
- **Signal charts.** Candles with ▲ buy and ▼ sell markers, shaded trades, one
  strip per rule showing when it was true, and each trade explained in a sentence.
- **Live forward-testing.** Strategies that pass trade on an OANDA practice
  account, with position sizing by risk, stops, circuit breakers and a regime
  rules engine.
- **Options paper trading.** Paper books for the wheel, put spreads, iron
  condors, call ideas and crash puts, priced from Questrade option chains with
  intraday quotes and take-profits.
- **Dashboard and alerts.** One page for everything that needs you, plus Discord
  alerts for opens, closes and anything to act on, and a daily check-in.
- **Accounts, journal and research.** Wealthsimple positions, a trade journal
  with plain-words trade stories, and the research log.

There's a serious theme and a WSB theme.

## How it's built

Two services share one PostgreSQL database:

| Service | What it does | Port |
|---|---|---|
| **`auro_be/`** (Rust: axum, tokio, sqlx) | The engine: OANDA prices and candles, strategy evaluation, order execution, trade management, backtests and the testing pipeline's maths, broker clients (OANDA, Questrade, Wealthsimple, Massive) | 3000 |
| **`opus/`** (Elixir: Phoenix 1.8, LiveView, Ecto, Oban) | The brain and the web app: every page, scheduling, the rules engine and regime detection, the strategy builder, options paper books, alerts, and every database migration | 4321 |

Opus tells the engine what to do over HTTP; the engine never calls Opus. OANDA is
the source of truth for trades. `auro_fe/` (Vue 3) is the older frontend, kept as
a portfolio piece; Opus serves the app.

`AGENTS.md` has the architecture rules; `research/` has the strategy research and
design plans; `CHANGELOG.md` lists what changed.

## Running it

### You'll need

- Rust (stable) and Elixir 1.20 / Erlang OTP 29
- PostgreSQL 17 (a database named `auro`)
- An OANDA practice account and API key
- Optional: Questrade (option chains and intraday bars), Massive (US daily
  bars), a Discord webhook (alerts)

### First time

```sh
git config core.hooksPath .githooks        # format on commit, CI checks on push
cp auro_be/.env_example auro_be/.env       # fill in (see below)
cd opus && mix setup                        # deps, assets, creates and migrates the database
```

Opus owns every migration: run `mix ecto.migrate` in `opus/` before starting the
engine, which refuses to start if a table it needs is missing.

### Day to day (development)

```sh
cd auro_be && cargo run          # engine on :3000
cd opus && mix phx.server        # app on http://localhost:4321
```

Run only one copy of each. To run both as background services that start at
login (macOS launchd), see `running_local/README.md`.

### Settings

Engine (`auro_be/.env`):

| Variable | |
|---|---|
| `DATABASE_URL` | e.g. `postgres://postgres:postgres@localhost:5432/auro` |
| `OANDA_API_KEY`, `OANDA_ACCOUNT_ID` | your practice account |
| `OANDA_BASE_URL`, `OANDA_STREAM_URL` | `https://api-fxpractice.oanda.com`, `https://stream-fxpractice.oanda.com` |
| `HOST`, `PORT` | default `127.0.0.1`, `3000` |
| `QUESTRADE_REFRESH_TOKEN` | optional; first-run token for Questrade |
| `MASSIVE_API_KEY`, `MASSIVE_BASE_URL`, `MASSIVE_CALLS_PER_MINUTE` | optional; US daily bars |

Opus (your shell in development; `running_local/opus.env` as a service, from
`opus.env.example`):

| Variable | |
|---|---|
| `DATABASE_URL` | same database |
| `OANDA_API_KEY`, `OANDA_ACCOUNT_ID`, `OANDA_BASE_URL` | same account |
| `AURO_BASE_URL` | the engine, default `http://localhost:3000` |
| `DISCORD_WEBHOOK_URL` | optional; alerts go nowhere without it |
| `SECRET_KEY_BASE`, `PHX_SERVER`, `PHX_HOST`, `PORT`, `POOL_SIZE` | release only |

Never commit `.env` or `opus.env`.

## Tests

```sh
cd opus && mix test                     # also creates and migrates opus_test
cd auro_be && cargo test
cd auro_be && AURO_TEST_DATABASE_URL=postgres://postgres:postgres@localhost:5432/opus_test \
  cargo test -- --include-ignored --test-threads=1   # database tests too
```

CI runs the same checks (`.github/workflows`); the pre-push hook mirrors it.

## License

See `LICENSE`.
