# Backlog (ranked)

The rule (Oct 30, 2026): we work one problem at a time. Anything new that turns
up while working it goes here, ranked by **need** (does it block real work or
decisions), **severity** (can it mislead us or lose money), and **cost** (how
big). We finish the current problem, then take the top of this list. Nothing
here jumps the queue unless it's losing money or data right now.

Scores: need and severity 1–3 (3 = high), cost S / M / L. Rank = need +
severity, cheaper first on ties. The bigger plan stays in
[`roadmap.md`](roadmap.md); this is the list of holes found along the way.

| # | Item | Need | Severity | Cost | Found |
|---|------|------|----------|------|-------|
| 4b | **The holdout's Sharpe bar (≥ 0.3) still books each trade on its close day** (`stats::annual_sharpe`). Fixing it changes a pass rule: bump `RULES_VERSION`, every result reads old again, and past holdouts can't be re-looked at freely. Your call. | 1 | 1 | M | Oct 30 |
| 5 | **Hold-for-months ideas on ETFs (Wealthsimple, by hand).** History loader built (Questrade daily back to 1995, split-adjusted); broker costs built. Still needed before trusting a result: dividends (~1.5–4% a year) added back, and each ETF's spread measured (10 bp default meanwhile). | 2 | 1 | L | Oct 30 |
| 6 | **Monte Carlo can't see same-day dips** (values at each day's last bar), so for intraday strategies its drop can read below the backtest's. | 1 | 1 | S | Oct 30 |
| 7 | **Ranked baskets' walk-forward restarts the warm-up** in the unseen half, so a 12-month ranking needs ~10 years of history. | 1 | 1 | S | Oct 30 |
| 9 | **Builder: a condition can be used once per side,** so "above the band now and 1 bar ago" can't be built (the engine accepts it). The form keys each condition's timing by the condition, so this means reshaping the form's rule items. | 1 | 1 | M | Oct 30 |
| 21 | **Flaky test: `InstrumentsLiveTest` "search and the market chips narrow the table"** failed once in a full run and passed alone (6/6); 5 more full runs all passed. Watch for it again before digging. | 1 | 1 | S | Oct 30 |
| 20 | **Baskets store their first market in `instrument`** (the column needs one). Clean fix: a markets column. | 1 | 1 | M | Oct 30 |

Items that change a pass rule (#4b, #6, #7) should land together with one
`RULES_VERSION` bump and one round of re-tests; that's your call, so they
wait for a yes.

Already scheduled elsewhere (not ranked here): audit round 4 fixes (weekend
services move), portfolio/roadmap items in [`roadmap.md`](roadmap.md).

## Done

- Oct 30: Each market is tested with its broker's costs (brokers table; Wealthsimple: no overnight cost, 10 bp default spread, no shorts). Migration + Opus patch staged; tester rebuild after the migration (was #0).
- Oct 30: The Questrade retry stops on a refused token (only a new token helps); the offline-broker alert already points at the Accounts page. Needs a live rebuild (was #19).
- Oct 30: The strategy list loads all strategies' runs in one query (was #18).
- Oct 30: A promote that gave up already raised a failed-job alert, but said it would run again; it now says to add the strategy from Squad and links there (was #16).
- Oct 30: Stuck-run alerts are built in `Alerts.build` (was #17).
- Oct 30: Archived runs left part-way read "Never finished", no Resume button (was #15).
- Oct 30: Squad's look-alike plays show the setting that differs (was #13).
- Oct 30: Together's forms (and the fragility pickers) have ids (was #14).
- Oct 30: Gettext templates re-extracted, WSB wording for the new strings. The Questrade token notices stay plain English in both themes (they aren't run through `copy/1`) (was #12).
- Oct 30: Pipeline queue limit checked, left at 2: the tester is its own process but shares the 8-core machine with live, and each stage already runs on several threads (`engine/parallel.rs`) (was #11).
- Oct 30: The luck check's spread measures ranked tries over months (information only). Needs a tester rebuild (was #10).
- Oct 30: Ranked baskets can buy the lowest first (reversal). Needs a tester rebuild (was #8).
- Oct 30: Together's Sharpe and how-they-move-together numbers come from the account valued at each day's close. Needs a tester rebuild (was #4; the holdout's Sharpe bar split out as #4b).
- Oct 30: A stage finishes and records its result when Opus hangs up part-way (it runs on its own task). A tester that stops mid-stage still leaves a "running" row; Opus shows it as stopped with Resume. Needs a tester rebuild (was #3).
- Oct 30: One meaning of "same strategy": strategy, basket and stuck-run pages match runs by settings, like Squad and the luck check (was #2).
- Oct 30: An old fail reads "Failed older rules; re-test it" on strategy and basket pages (was #1).
- Oct 30: Squad warns before a re-test that would take a second look at the holdout (was #1).
- Oct 30: Questrade reconnects without a restart (Accounts token form + background retry). Needs a live rebuild/restart to deploy.
- Oct 30: Stuck pipeline runs show "Stopped part-way" with Resume (holdout asks first); the dashboard reports them, never resumes.
- Oct 30: Monte Carlo timeout checked, no change: the heaviest run (NAS100 M5, 9 years) takes 7 s against a 120 s limit; the long times seen were a bookkeeping artifact (`inserted_at` kept from the first run).
- Oct 30: Rules-version stamp on every test result (Rust in the tree; Opus side + migration staged, see the deploy steps in the morning summary).
- Oct 30: `QuestradeClient` prints without its tokens.
