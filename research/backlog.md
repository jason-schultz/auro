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
| 42 | **Options alerts with Log trade:** an options play alerted like the share alerts, logged into the options records with the account it's in; options rows say which account (paper book or a real one). | 2 | 1 | M | Oct 30 |
| 43 | **Share alerts decide at 15:45, the tests at the close.** Record what the close said beside each alert, so the gap is a number, not a guess. | 1 | 2 | S | Oct 30 |
| 28 | **Adding to positions isn't modelled** (one position per market): averaging down, fixed-weight rebalancing and DCA are strategies of their own, untestable today. | 1 | 1 | L | Oct 30 |
| 9 | **Builder: a condition can be used once per side,** so "above the band now and 1 bar ago" can't be built (the engine accepts it). The form keys each condition's timing by the condition, so this means reshaping the form's rule items. | 1 | 1 | M | Oct 30 |
| 20 | **Baskets store their first market in `instrument`** (the column needs one). Clean fix: a markets column. | 1 | 1 | M | Oct 30 |

Already scheduled elsewhere (not ranked here): audit round 4 fixes (weekend
services move), portfolio/roadmap items in [`roadmap.md`](roadmap.md).

## Done

- Oct 31: Options books: open and closed trades listed under their own headings; "This book's cash" with a line saying each book is its own paper account that started with $100,000 (the cash differed between books because each is a separate account); the underlyings' prices now from Questrade beside the price the book was last valued at, on the book and on an open trade (the 15:45 New York snapshot is the day's last) (was #41).

- Oct 31: Rules version 3, one bump for three pass-rule fixes: the annual Sharpe (the holdout's ≥ 0.3 bar, the backtest's figure) comes from the account valued every day instead of each trade booked on its close day (was #4b); Monte Carlo redraws each day with its low (`Outcome::daily_lows`), so an intraday strategy's dip that recovers by the day's last bar counts in its drawdowns, as in the backtest (was #6); a basket's walk-forward unseen part warms up on the bars before it and a ranking rebalances from the split, as the holdout does, instead of restarting the look-back (was #7). Every earlier result reads as old until re-tested; needs a tester rebuild.

- Oct 30: Share alerts: a strategy on a market tested as shares held goes live as share alerts (never OANDA trades), $500 a buy by default, changeable on its page. At 15:45 New York the live engine decides each switched-on one on its daily bars plus the day so far, by the backtest's own rules, long only (`engine/share_alerts.rs`, `POST /api/share-alerts/evaluate`, tested to match the backtest's every entry and exit). Buys and sells go to Discord and stay on the Dashboard with Log trade (filled in from the alert; pick the account and when it filled), which updates that account's holdings and cash; "Didn't trade", or no log by the next check, counts as not traded. Logged fills are the only record of what's held. Needs the migration, a live rebuild and an Opus restart (cron).

- Oct 30: The flaky Instruments test was a Postgres deadlock: five test files ran in parallel adding the same instruments (SPY, EUR_USD…) in different orders, and the unique keys made their sandboxed transactions wait on each other. Those files now run serially; 6 full runs and 25 solo runs clean (was #21).
- Oct 30: Dashboard alerts are one line each (level, title, "Details ▸" folds out the detail and what to do); the three most urgent show, the rest behind "N more" (was #23).
- Oct 30: `POST /api/strategy-configs` refuses a market that can't be tested yet (no broker, dividends not loaded) with why, before storing anything (`Coordinator.untestable/1`) (was #26).
- Oct 30: Paper money is kept apart: the engine marks each broker account `paper` (OANDA from its API host: `fxpractice` is practice; Questrade and Wealthsimple real) and names OANDA's account Practice or Live accordingly; the Accounts total, allocation and net worth count real money only, the paper total is said beside it and has its own line (OANDA's daily value), the account table and the Journal's OANDA and Options tabs carry a "paper" tag. Needs a live rebuild (was #40).
- Oct 30: Clickable Journal lists have no lines between rows (a square line beside the rounded highlight looked broken); rows sit a hair apart instead (`TradeStory.list_table_class/0`).
- Oct 30: The Journal has three tabs (OANDA, Options, Holdings) with the same five cards on each (last 30 days, worst drop, costs, how trades end, this week; `Journal.Cards`), each filled from its own records and saying why when it has nothing, and each tab's value over time as a line (OANDA's daily account value, the options books' running closed-trade P&L, the holdings' closes). Net worth over time is a line on the Accounts page, from every account's value recorded at each close (`account_values`, in the holdings migration; `SnapshotWorker`). One chart component for all of them (`ValueLine`: one series, low and high, a hover per day, a table view) (was #36).
- Oct 30: The 15-minute Wealthsimple re-price resolves each holding through its recorded Questrade id (`identity::symbol_id_for`, shared with the quotes endpoint) instead of searching by name every time. Needs a live rebuild (was #34).
- Oct 30: Saving holdings adds any symbol not in the instruments yet (as a stock; the Instruments page can make it an ETF), before the engine links it, so it's re-priced, its bars stored and its history and dividends loaded (`Accounts.track/1`) (was #39).
- Oct 30: Journal rows' highlight is inset evenly (padded first and last cells, rounded ends) and the pills are outlined with a ring instead of a 1px border, shared by the strategy chips and the tabs (`TradeStory.chip_class/1`, `row_class/1`) (was #37).
- Oct 30: The Wealthsimple holdings have a history: each trading day's close is recorded at 16:10 New York (`SnapshotWorker`, `holding_snapshots`); the Accounts page shows "Holdings over time" (value, the day's move, below the high, worst drop over 90 days, the last ten closes against cost); the Dashboard raises a check when they fall 5% or more at today's close; the Discord write-ups say how far they moved over the day or week. Needs the migration and an Opus restart (cron) (was #38).
- Oct 30: Canadian listings (no dividend history: Massive is US only) are tested without past dividends instead of refused, and their results say so (the engine's `dividends_recorded_since`; just-holding is compared the same way); their new dividends are recorded daily from Questrade's latest-dividend fields (`DividendRecordWorker`, 20:40 New York) and paid in tests from then on, without clipping the test to them. Check after the live rebuild that Questrade's `dividend` is per payment, not a year's (was #24, options 2 and 3).
- Oct 30: The Wealthsimple accounts and holdings are edited on the Accounts page ("Edit accounts and holdings"), moved off the frozen Vue page: type, number, currency, cash, and each holding's symbol, shares and average cost; a managed account without listed holdings takes a typed holdings value. Saved through the engine's replace-all. Found while on it: an account's value used a typed "total equity" that never moved with prices (the Non-registered account counted $0); it's now cash plus its holdings at their latest Questrade price. Nothing contacts Wealthsimple.
- Oct 30: A stock or ETF gets itself ready to test: adding it, or setting its test broker to one that holds shares, queues `ShareHistoryWorker`, which loads its Questrade daily history back to 1995 (unless it already has 3+ years) and then its dividends where Massive covers it, through the live engine, retried on failure. Live by hot reload (was #33).
- Oct 30: An offline broker's alert gives that broker's play: OANDA maintenance (a 503) says nothing to do and that open trades keep their stops at OANDA, another OANDA error points at the log and the API token, Questrade keeps its token advice (was #30).
- Oct 30: ETF and stock spreads are measured (was #5's last piece): Questrade bid/ask every 15 minutes 10:00–15:45 New York for every market tested as shares held (`SpreadWorker`, `spread_samples`), and after the close each market's `spread_bps` becomes the median of its last 30 days once it has 40 samples (about two sessions); until then the broker's 10 bp. The Instruments page shows which. The quotes endpoint now resolves listings through their recorded Questrade id instead of searching each time. Needs the migration, an Opus restart (cron) and a live rebuild.
- Oct 30: Dividends load from a button, not a script: "Load dividends" on the Instruments page row of any market held as shares, and beside the builder's "can't be tested" message (Opus asks the live engine, as the script did). A listing with no dividend source (Canadian: Massive is US only, #24) says so instead of pointing at a script that can't work.
- Oct 30: Editing a strategy and saving tests it on the instrument picked for the preview too (it re-tested only the instruments it was on, so a strategy on none tested nothing and said "running again on "), and the message says what started and why anything didn't. A market held as shares whose dividends were never loaded is refused up front with what to do (`Instruments.untestable/1`), on every path into the pipeline.
- Oct 30: Discord: the 16:30 New York check-in is now the day's write-up (live closes with best and worst, options opened and closed, holdings against cost, what to look at), and Fridays 17:00 New York send the week's, built in code (`Dashboard.Summary`). The Friday job needs an Opus restart (cron config) (was #32).
- Oct 30: Pipeline stages announce themselves over PubSub (`Pipeline.Events`, one Oban telemetry hook), on a topic per strategy (timeframe + trade settings, how pages match results) and one for all: the basket and strategy pages hear only their own strategy's tests, the Strategies list hears all (gathered per half second). No polling left on those pages (was #31).
- Oct 30: The Dashboard is pushed, not polled: one process (`Dashboard.Feed`) gathers it when a job finishes or fails, a live trade opens or closes (Postgres trigger → NOTIFY, migration staged), or a suspension or pause changes, plus a once-a-minute look for what only looking can see (engine quiet, stale data), and only while a Dashboard is open. Needs the migration, then an Opus restart.
- Oct 30: The Journal has an Options tab: the paper books' 30-day numbers (closed, made money, P&L, premium kept) and their closed trades, each told in options terms (what was sold and bought, premium taken in or paid, how it ended, share kept), linked to its book on the Options page (was #22).
- Oct 30: The holdings' 16:00 New York run counts as the close again (it was skipped every day for firing a fraction of a second past 16:00:00), so the Bag ends the day on the closing price (was #29).
- Oct 30: Splits. Dividends are stored per share held today (a payment before a 2:1 split halved, as the bars are; EEM was 3×, SMH and XLE 2× too big before their splits), and a big payment the bars already price in is left out (XLF's 2016 XLRE spin-off, $4.44, counted twice). A split after today: the nightly daily bars (Massive or Questrade) spot the new scale against at least 2 stored days that all moved alike, rescale every older stored bar, and reload that fund's dividends. Needs a live rebuild, then `scripts/load_dividends.sh` (was #25; the dividend scale found while on it).
- Oct 30: Long-only share results show just holding the same funds beside them, compared on the account valued daily. Needs a tester rebuild (was #27).
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
