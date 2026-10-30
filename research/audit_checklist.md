# Audit checklist

How to re-run Auro's audits so each run looks at the same things and can be
compared with the last. Rounds 1–4 ran Oct 28–30, 2026; their findings are
summarised under "Fixed — must stay fixed" below.

## When

- **Correctness rounds (1–3):** after each big feature, and once more before
  real money.
- **Infrastructure round (4):** after the move to launchd services and Postgres
  off Docker, then every month or two.

## How

1. **Read-only.** No edits, restarts or migrations during an audit; SQL is
   SELECT only; requests to the running apps are GET only.
2. **Reviewers, split by area.** Each reads its scope and reports findings with
   file:line, a concrete scenario (state → wrong result), evidence and severity.
3. **An independent checker** re-verifies every finding against the code and the
   live data: confirmed, partly (what's off), or rejected (why). Only checked
   findings reach the list.
4. **Rank by money risk:** wrong trade decision > wrong data stored > misleading
   screen > latent.
5. **Plain-words list** to the owner, who decides what to fix. Record the round's
   findings (what was found, what was fixed, what was deferred).

## Scope per round

| Round | Area | Main files |
|---|---|---|
| 1 | Backtest math, validation stats, numbers the pages show | `auro_be/src/engine/{strategy,pipeline,stats,report,kfold}.rs`, `opus/lib/opus/pipeline/`, journal and safety pages |
| 2 | Live engine failure handling, Opus jobs | `auro_be/src/engine/live/`, `brokers/oanda/`, Opus reconciler, dashboard alerts, Oban workers |
| 3 | Options and market data | `brokers/{questrade,massive}/`, `api/{questrade,massive,options}.rs`, `engine/options/`, `opus/lib/opus/options/`, `opus/lib/opus/market_data/` |
| 4 | Security and operations | bind addresses, CORS/Origin/Host checks, secrets, Postgres exposure, backups, supervision, dependency advisories |

## What to look for (the mistakes that kept coming up)

1. **Dates and time.** New York dates, not UTC (`Opus.Clock.today`, not
   `Date.utc_today`). Market-time crons in `America/New_York`, so DST can't shift
   them. Dates compared as dates (`Enum.max(list, NaiveDateTime)`), not as
   structs. Index daily bars: Friday stub bars.
2. **Data age.** Every decision checks how old its input is (bars, chains,
   quotes, NAV, FX) and refuses stale input. Every page says what date its data
   is from. Vendor publish times are checked against reality, not assumed.
3. **Partial failure.** One bad item doesn't discard a batch. A failed job
   returns an error, not `:ok`. Replacing rows happens in a transaction and keeps
   what it can't recompute, including user choices like dismissals. "Clear" never
   deletes history.
4. **No silent guesses.** No "first search hit", rate 0.0 or stale price filled
   in without saying so: error, or say it on the page.
5. **Rules apply where intended.** An entry filter doesn't block an exit. Live
   and backtest share bar timing, re-entry and exit rules.
6. **Explicit order.** Picking the top N sorts by the score. A shared cap is
   filled by score across groups, not in loop order.
7. **Outside services.** Single-use tokens are kept in memory before they're
   saved, and the save is retried. Broker behaviour is checked, not assumed
   (OANDA netting). Rate limits: wait and retry once.
8. **Honest labels.** Every number matches its label.
9. **Tests.** No pass-or-fail by chance; no dependence on today's date or time.
10. **Oban and Opus.** `unique` does nothing with `insert_all`. Retries back off
    minutes, not seconds. Long fan-outs get their own queue. Editing files
    reloads the running dev Opus; editing `config.exs` breaks pages until a
    restart.
11. **Infrastructure.** Apps bound to localhost; no `*` CORS; Host/Origin
    checked; a shared secret on Opus → Rust calls; Postgres not exposed and not
    on the default password; nightly backups that have been restored once;
    services restart themselves; an outside heartbeat; `mix hex.audit` and a
    Rust advisory check clean; practice vs live can't be mixed up.

## Fixed — must stay fixed

A re-run confirms these haven't come back.

**Round 1 (Oct 28)**
- Paper books read only chain snapshots, never intraday leg quotes.
- Friday index stub bars are folded into the next bar.
- No same-bar re-entry after a stop.
- "Passed" badges reflect today's standard.
- The Monte Carlo drawdown counts losses before the first gain.

**Round 2 (Oct 29)**
- No opposite-direction entry on an instrument with an open trade (netting).
- Startup refuses blind spots: position prefill, rule limits and unit caps.
- Open positions are synced with OANDA periodically.
- Tasks are supervised, and quote age is checked in sizing.
- One failing book, or one alert error, doesn't stop the rest.

**Round 3 (Oct 29)**
- US daily bars are fetched at 07:00 New York, and the scan refuses an old
  close.
- Condors and spreads close even when a wing has no bid.
- An expiry settles on the 16:00 closing print when the daily bar is missing.
- The Questrade token is kept in memory before it's saved.
- A symbol search takes exact matches only.
- A stock split triggers a full re-fetch.
- Ideas are picked by score across all underlyings.
- "Clear failures" hides jobs instead of deleting them.

**Round 4 (Oct 29–30): found, deferred to the services move**
- The old Vue dev server exposed the engine to the network.
- Postgres was open to the network on the default password.
- No backups.
- `*` CORS on both apps.
- Opus runs in dev mode with no supervision.
- No practice-vs-live guard.
