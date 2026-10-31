# Roadmap after the audits (2026-10-29)

What comes next, in order, and the ideas parked along the way. Nothing here is built
yet unless it says so. The order holds until we change it: the audits come first,
so everything below builds on a stable, hardened, correct base.

Holes found along the way go to the ranked [`backlog.md`](backlog.md), not fixed on the spot.

## 1. Finish the audits

Rounds 1 (backtest math, validation stats, the numbers Opus shows) and 2 (live
engine failure handling, Opus jobs) are done and fixed. Two rounds remain:

- **Round 3, options and market data.** Questrade and Massive ingest, the paper
  books' math (fills, rolls, the 21-day close, P&L), the 15-minute quote checks,
  the options scan. Both bugs found on Oct 29 (a contract listed twice, the
  Questrade rate limit) came from here.
- **Round 4, security and ops.** Rust's endpoints (no auth, localhost only),
  secrets and token rotation, database backups, restart behaviour, launchd and
  release builds, what changes for real money.

All four rounds ran Oct 28–30; round 4's fixes ride on the services move and
Postgres leaving Docker. Re-running them: [`audit_checklist.md`](audit_checklist.md).

Loose ends meanwhile:
- DONE Oct 30: the three index dip-buy assignments re-tested under today's rules
  (after the stub-bar fix): SPX500 D passes every stage, holdout too; NAS100 D
  fails the luck check (0.77, needs 0.80) and is still switched on (your call);
  EU50 D fails the backtest (t 1.14, needs 2.0) and is off.
- A nightly `pg_dump` backup, ahead of round 4.

## 1b. Track Wealthsimple holdings like any other security

Built Oct 30 (re-priced every 15 minutes in the session; intraday and daily
bars nightly; Questrade quotes HODL.CN fine). Still open: account linking moves
from `auro_fe` to Opus. Every security held on Wealthsimple is tracked even
though it can't be traded by algorithm: a row in the instruments table, regular
Questrade quotes, shown on the same pages as everything else.

- The tracked list follows the holdings: a new position starts tracking, a sold
  one stops. No hand-kept list.
- Check that Questrade's API quotes Canadian Securities Exchange listings
  (HODL.CN); TSX and TSX Venture (FLT.TO, PNG.VN) should be fine.
- Wealthsimple account linking lives only in `auro_fe` today; it moves to Opus
  as part of this (see Parked: deprecate `auro_fe`).

## 2. More strategies through the gates

The lab only pays off with several strategies that pass. Today two edges have
survived honest testing. Feeding new ideas through the pipeline runs alongside
step 3, not after it. Gaps in the gates to close as part of it: a penalty for
testing many variants (deflated Sharpe), a parameter-stability check, rotating
out-of-sample periods. Keep the old pipeline history (`strategy_configs`,
`strategy_evaluations`): the count of everything tried is what keeps those
penalties honest.

### Portfolio backtests (soon, the user's priority, Oct 30)

The pipeline tests one market at a time. Several well-documented ideas only
work as a portfolio, so a per-market test can't judge them fairly. Fresh ideas
round 1–2 (Oct 30) hit this twice:
- **Time-series momentum** (Moskowitz, Ooi & Pedersen 2012): the result comes
  from holding every market at once, each sized to the same risk (volatility
  scaling). One market at a time it failed everywhere, a weak verdict.
- **FX carry** (Lustig, Roussanov & Verdelhan 2011): the papers sort currencies
  by interest rate and hold the top against the bottom. Single pairs mostly
  lost, also weak.

Needed:
- A backtest over a basket: positions in several markets at once, rebalanced on
  a schedule (monthly), each sized by its recent volatility, with OANDA
  financing on every holding. One account curve for the whole basket.
- Cross-market blocks: rank markets by a signal (carry, 12-month return) and
  take the top and bottom.
- The gates judge the basket's curve: same backtest, walk-forward, luck check
  and Monte Carlo standards. Its tries count against its own family.
- Missing data for carry: MXN, ZAR and HKD pairs have no candles (inactive).
- Then re-run momentum and carry the way the papers describe them.

### Next, after time rules + baskets land (agreed Oct 30)

1. **Count settings changes as tries.** The luck check counts markets, not
   settings tweaks in the builder, so heavy builder use quietly weakens every
   pass. Count distinct settings per recipe family too.
2. **One place to add a block.** BUILT Oct 30. Each Rust block declares its
   catalog entry next to its code (`catalog()`: name, what it watches,
   settings with defaults, ranges and why, ports with their plain words,
   drawn values, own-stop words); `engine/catalog.rs` lists them and
   `setting_range` reads from it. A test writes `opus/priv/block_catalog.json`
   and fails when it's stale; Opus compiles it into the builder
   (`Blocks`) and the plain-words rules (`StrategyWords`). To add a block:
   write it with its `catalog()`, add its `Component` variant and its line in
   `catalog::blocks()`, run `UPDATE_CATALOG=1 cargo test catalog`, then put
   its type in a group in `Opus.Trading.Blocks` (a test fails until you do).
3. **The tester runs on its own.** BUILT Oct 30. Backtests, pipeline stages,
   reports, the sensitivity grid and the Together replay run in a second
   binary, `auro-tester` (port 3001, `AURO_TESTER_URL` in Opus); the live
   engine no longer serves them (`api::live_router` / `api::tester_router`,
   checked by `auro_be/tests/router_modes.rs`). Hard rule from now on:
   testing never slows down live trading.

## 3. One signal, several actions (Phase 3 of `strategy_assignments_plan.md`)

Any strategy that passes can be assigned an action per instrument: trade it on
OANDA, alert you to buy or sell shares, or open an option in a paper book. One
signal can fan out to several assignments at once.

Needed:
- Rust honours `live_strategies.action`; for anything but `oanda` it records the
  signal and places no order.
- Migration: the unique index `uq_live_strategies_instrument_type_params` must
  include the action, plus a "trade on" symbol (a CFD signal acting on an ETF's
  options).
- Opus picks up new signals every minute and carries out the action. Options
  reuse the paper engine's leg building and management.
- Opus pages: an action picker on assignments; the Together page shows one
  signal's trades side by side.

### Share alerts first

They fit real money at today's account size (no leverage, no minimum unit,
fractional shares on Wealthsimple, $0 commission).

- Alerts fire at the strategy's own decision time. A strategy that decides on
  the daily close is checked at 15:45 New York on real-time Questrade quotes, so
  the alert arrives in time to buy before 16:00. Intraday strategies alert at
  their bar checks (needs intraday stock data). Event-driven ones alert the
  moment the setup happens.
- Each alert gives the ticker, a dollar amount, a suggested limit price (alert
  price plus a small buffer) and the exit rule.
- You log the fill (a button or command); the Journal compares it with the alert
  price, as execution quality does for OANDA trades.
- Backtests assume the same costs: spread, slippage, fills at the close and at
  the next open both tested, and a limit that sometimes doesn't fill.
- Test on liquid ETFs (SPY, QQQ, XIU, VFV), not small venture-exchange stocks.

Then options alerts. Open questions: what a short signal becomes as an option
(a long put works in a TFSA; spreads need a margin account); whether options
exit on the strategy's exit or the paper engine's rules (recommended: the paper
rules); the option leg can't be backtested without Massive's paid history, so it
is forward-tested on paper only.

## 4. Discord bot

Two-way commands in Opus (today Discord is one-way: the webhook in
`opus/lib/opus/dashboard/discord.ex`). First version read-only: `/positions`,
`/books`, `/pnl`, each replying with a chart image and a plain-words summary.
Commands that change things come later, limited to your Discord user with a
confirm step.

- Outbound gateway connection, so it runs from the Mac with no public URL. Needs
  a Discord library (Nostrum) and a server-side chart renderer: new
  dependencies, pick together before adding.
- Setup: a bot app and token in the Discord developer portal (secret in the
  environment), invite it to the server, optionally a dedicated channel.

## 5. Integrations settings page

A Settings → Integrations page where broker and data keys are entered once.

- Keys stored encrypted in the database, master key in the environment. The page
  shows "connected, ends …a7f3", never the key.
- Rust decrypts them from the database at startup (it never calls Opus). A key
  change reconnects live and re-runs the position sync, no restart.
- Base URLs and practice-vs-live come from the integration type, never typed in,
  so practice settings can't be pointed at real money by accident.
- The Questrade refresh token already lives in the database: the precedent.
- Rule of thumb: `.env` holds what rarely or never changes (database URL, the
  master key). Anything a user may change (broker keys, tokens, preferences)
  lives in user settings in the database and applies without a restart.
- **Time zone** belongs here too. Today it's one install-wide setting
  (`display_zone` in Opus config). Later: picked up automatically from the
  browser when a page opens, with a per-user override in settings (e.g. show
  everything in New York time). The automatic part needs no logins and could
  come first, falling back to `display_zone`.

## 6. Broker router in Rust

Engine code says "buy X, this size, this stop" in Auro's terms; a router picks
the account's broker adapter, which translates and calls it.

- Two interfaces: execution (OANDA, Alpaca, Webull, IBKR) and market data
  (Massive, Questrade, OANDA candles). Data vendors don't fake order methods.
- Capability flags per adapter: server-side trailing stops, netting vs hedging,
  fractional units, options. The engine checks them instead of assuming
  (the general form of the Oct 29 netting guard).
- The router picks the adapter from the account's saved integration (step 5).
- Build it with the second execution broker, not before. Until then every OANDA
  call stays inside `auro_be/src/brokers/oanda/`.
- We build our own adapters. SnapTrade (below) is the fallback for a broker we
  can't connect to ourselves, not the plan.

Broker candidates (checked Oct 29):
- **Interactive Brokers Canada:** full trading API; the established choice.
- **Webull Canada:** OpenAPI needs $100 net account value, but its docs cover the
  US and Hong Kong only; ask support@webull.ca whether Canadian clients can use
  it. Its Oct 27 2026 AI-assistant feature prepares orders you confirm in the
  app. $2.99 per trade.
- **SnapTrade (fallback only):** the paid service that connects a bunch of
  brokers behind one API, useful for Canadian investors. Look into it only for a
  broker we can't connect to ourselves. Free tier covers 5
  connections with trading. Webull Canada trading supported; Wealthsimple listed
  as read/trade but connects with your login (no official API); Questrade likely
  read-only. Use read-only first (sync Wealthsimple holdings), trading only once
  verified.
- **Questrade:** personal API keys are read-only (prices, accounts); order
  placement is for approved partners.

## 7. Logins and other users, last

Self-hosted, one user per install, is the simple path. A shared service means
isolating users, holding other people's broker keys, and possibly Canadian
securities regulation for trading on others' behalf: check before going there.

## Parked

- **Deprecate `auro_fe`:** frozen Oct 29 (README, AGENTS.md, CI removed). Before
  the folder goes, move Wealthsimple account linking and the pipeline status
  list to Opus, then remove the Opus JSON endpoints only Vue uses.
- **A product name:** shortlist so far Temper, Whetstone, Wrinkle; more welcome.
- **Event-driven entries:** strategies that enter the moment a level breaks
  rather than at a bar close; each needs a backtest at that timing.
- **Taxes, January 2027:** claiming capital losses from earlier years.
- **Real money:** months away. Needs a forward-tested track record, the audits
  done, an OANDA live account (or another broker), a staged start at tiny size
  with a hard daily loss cap, and an account big enough for the strategy's
  minimum size at 1% risk.

### Follow-ups from the Oct 30 sweep
- Monte Carlo still resamples whole trades, so its worst-drop figure misses drops inside long trades (now inconsistent with the backtest). Fix: resample blocks of the daily-valued account returns.
- Daily Sharpe and correlations for single markets and Together are still booked on the day a trade closes.
- A ranked basket's walk-forward unseen half restarts the warm-up, so a 12-month ranking needs ~10 years of history.
