# Share alerts: plan for review (Oct 30, 2026)

The step that lets a tested strategy work with real money at Wealthsimple: when
a strategy assigned to a stock or ETF says buy or sell, you get an alert in
time to act, you log what you did, and the Journal compares your fills with
the alerts. Nothing contacts Wealthsimple; you place every order by hand.

Roadmap section 3 ("One signal, several actions") has the background. This is
the concrete version, with the choices that are yours marked **Decide**.

## What exists

- `live_strategies.action` (jsonb, default `{"type": "oanda"}`): every
  assignment already carries an action. The engine ignores it today: every
  enabled assignment trades on OANDA.
- Stock and ETF daily bars (Questrade history, Massive nightly), dividends,
  measured spreads, and the tests already grade share markets with
  Wealthsimple's costs, long only.
- Discord alerts (one-way webhook) and the Dashboard alert list.

## How it would work

1. **You assign a passing strategy to a stock or ETF with the action "share
   alert".** Only daily strategies at first: they decide once a day, at the
   close, which a person can act on.
2. **At 15:45 New York on trading days** Opus asks the live engine to evaluate
   every share-alert assignment (scheduling in Opus, the decision in Rust, as
   for everything else). The engine takes the stored daily bars plus today's
   bar so far from a real-time Questrade quote, runs the same rules the
   backtest ran, and answers: buy, sell, or nothing, per assignment. It places
   no order.
3. **Opus sends the alert** (Discord and the Dashboard): ticker, buy or sell,
   how much, a limit price (the 15:45 price plus a small buffer), and the exit
   rule in words. Fifteen minutes before the close leaves time to place it.
4. **You log what you did** on the strategy's page: bought or sold, shares,
   price (or "skipped"). That's the only record of your position: the next
   day's check knows you hold it only because you said so.
5. **The Journal gets a Shares tab** (or the Holdings tab grows one): each
   alert beside your fill, the gap in basis points, missed alerts, and the
   same five cards.

## Decisions

1. **How much to buy.** **Decide.** Options: (a) a fixed dollar amount per
   assignment that you set (simplest, recommended to start: e.g. $500); (b) a
   share of an account's value, sized to the strategy's risk like OANDA's
   trades (needs to know which account and its cash, all hand-entered).
2. **Which account it's for** (TFSA vs non-registered changes taxes, not the
   alert). **Decide**: a label on the assignment, shown in the alert. No money
   moves either way.
3. **The decision price.** The backtest decides on the close; the alert
   decides on the 15:45 price. They usually agree; on a day the last 15
   minutes cross the line they won't. Recommended: test both (decide at the
   close vs at 15:45) once, on the strategies you'd assign, so the gap is a
   number, not a guess.
4. **A missed alert.** If you don't log anything by the next morning, the
   alert counts as skipped and the strategy is treated as not holding.
   Recommended, so the engine never assumes a trade you didn't make.
5. **Exits on a holding you entered yourself.** The strategy's exit rule
   alerts a sell only for positions you logged from its alerts; your other
   holdings are never touched.

## What gets built

- **Migration (Opus):** `share_alerts` (assignment, day, side, ticker, alert
  price, limit, amount, sent at) and `share_fills` (alert, shares, price, at,
  or skipped); the unique index on `live_strategies` widened to include the
  action, so one strategy can have an OANDA assignment and a share alert on
  different markets.
- **Rust (live):** `POST /api/share-alerts/evaluate`: the share-alert
  assignments' signals on daily bars plus the Questrade quote, no orders; the
  live evaluator skips assignments whose action isn't `oanda`. Tests: the
  evaluation matches the backtest's decision on the same bars.
- **Opus:** the 15:45 job, the alert (Discord + Dashboard), the action picker
  on assignments, the fill form, the Journal tab, and the daily write-up line.

Size: large, about the scale of the broker-costs work. It touches the live
engine's evaluator (the skip), so it ships with a live rebuild and a check
that OANDA assignments behave exactly as before.

## Not in this step

Intraday share strategies (need intraday stock data in the live engine),
options alerts, and two-way Discord (logging fills by command) come later.
