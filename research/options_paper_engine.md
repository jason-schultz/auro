# Options paper engine

**Approved and built 2026-10-26.** US$100,000 book, SPY + IWM, one position each;
commission US$0.10 per contract (Wealthsimple charges $0; about $0.07 of exchange and
regulatory fees, rounded up). Code: `Opus.Options.Paper` (DB and book),
`Opus.Options.Paper.Wheel` (the rules, pure), `Opus.Options.PaperWorker` (cron 02:45 UTC
Tue–Sat); migration `20261026010000_create_paper_options.exs`. A covered call's strike
floor is the assigned strike (premiums received don't lower it).

Written 2026-10-26. Forward-tests the cash-secured put strategy from
`strategy_options_csp_v1` (memory) on the nightly Questrade chain snapshots. There is no
option history to backtest on yet: snapshots began 2026-10-23, so this is how the
strategy gets judged.

## Strategy (v1, as already specced: "the wheel")

1. **Sell a put:** 30–45 days to expiry, delta closest to −0.25, on each underlying with
   no open position. Cash-secured: strike × 100 is reserved.
2. **Manage nightly:** buy it back once 50% of the premium is captured, or at 21 days
   to expiry, whichever comes first, unless it is in the money then: hold to expiry.
3. **At expiry:** out of the money → keep the premium. In the money → assigned 100
   shares at the strike.
4. **Holding shares:** sell a covered call, 30–45 days, delta closest to 0.30, strike at
   or above the cost basis; same 50% / 21-day management. Called away at expiry if in
   the money, which ends the cycle and starts a new put.

One position per underlying. No volatility filter or earnings rules in v1.

## Fills (deliberately pessimistic)

- Sell at the **bid**, buy back at the **ask**. No fills between bid and ask.
- Marked nightly at the **mid**.
- Expiry settles against the last stored spot price before the expiry date.
- Commission per contract: configurable (needs the user's Wealthsimple rate).
- No fill if the quote has no bid, or a bid-ask spread over 10% of the mid.

## Account

A separate paper book in USD, not the OANDA practice account. With US$100,000:
**SPY and IWM, one contract each** (≈ $76k + $23k reserved). QQQ and single names wait
for a bigger book or smaller underlyings.

## Where it lives

All in **Opus**: it runs once a night on stored data, places no orders, and has nothing
to do with price ticks (the Rust/Opus split rule).

- **Tables (one migration, the user runs it):** `paper_option_positions` (the open and
  closed legs) and `paper_option_events` (every open, mark, close, assignment and
  call-away, so the history can be replayed).
- **`Opus.Options.Paper`:** pure functions for choosing a contract, the management rules
  and settlement, unit-tested on hand-built chains; plus a small DB layer.
- **`PaperWorker`:** Oban cron at 02:45 UTC Tue–Sat, after the chain snapshot (02:00) and
  the ideas scan (02:30).
- **Options page:** a "Paper book" section with open legs, shares held, premium
  collected, P&L against simply holding SPY/IWM, with WSB twins ("Theta gang").

## What it's judged on (fixed now, checked after 12 months)

- Total return vs holding the same dollars in SPY/IWM, and worst drawdown vs holding.
- Premium kept as a share of premium sold.
- Not win rate: puts win about 80% of the time by construction; the losses are what
  matter.

## v2: multi-leg trades and four more strategies (2026-10-26)

Approved by the user on 2026-10-26; rules fixed here before any of them trade.

**Built 2026-10-26.** Migration `20261026020000_add_paper_option_trades.exs` (trades table,
leg `side`, event `strategy`, wheel legs backfilled one trade each). Rules:
`Opus.Options.Paper.Structures` (put spread, iron condor), `Opus.Options.Paper.LongOptions`
(ideas, crash puts), shared `Paper.Pick` (fills, delta picking) and `Paper.Legs` (cash,
payoff, max profit/loss, break-evens). `Opus.Options.Paper` runs every book nightly and
reads each back; `PaperWorker` logs per book. Page: `OpusWeb.Components.PaperTrades`
(the four new books), `PaperParts` (shared pieces), book selector in `PaperBook`
(`?view=paper&book=`). Payoff charts for whole trades: the Rust `/api/options/scenarios`
endpoint takes an optional `legs` array (`engine::options::scenarios::analyze_structure`).
Config: `Opus.Options.Paper` `books:` (underlyings per book).

**Band change for the condor:** with the 10% band the lowest stored put delta was about
−0.11, so the condor's −0.05 put wing didn't exist in the data. `OptionsChainWorker`
`strike_band_pct` is now **0.20**. No trading rule changed; more quotes are stored nightly.

### Engine changes

- **Trades group legs.** A new `paper_option_trades` table: one row per trade (strategy,
  underlying, structure, opened/closed dates, status). Every leg (`paper_option_positions`)
  belongs to a trade. Legs of a spread or condor open together and close together.
  The wheel's existing legs are backfilled one trade per leg.
- **Long legs.** Legs get a `side` (short/long). A long leg pays the ask to open and is
  sold at the bid to close; its P&L sign is the reverse of a short leg's.
- **Books per strategy.** Each strategy is its own US$100,000 paper book (a `strategy`
  key on trades and events), so the results compare like for like.
- **Collateral.** Wheel puts reserve strike × 100. Credit spreads and condors reserve their
  maximum loss (width × 100 − credit). Long options cost their premium and reserve nothing.
- **Settlement of spreads.** If a spread or condor is still open at expiry (no quote to close
  it, for example), each leg settles at its intrinsic value in cash. Only the wheel takes
  delivery of shares.
- **Band limit.** The chain snapshot stores strikes within 20% of spot (10% before v2) and
  up to 45 days out. A leg that drifts outside has no quote: it is held and settled at
  expiry.
- **Fills on every leg.** A structure opens or closes only when every leg's quote is
  fillable (a bid, spread within 10%); otherwise it's held, and settled at expiry if it
  never gets a fill.

### The strategies

All: 30–45 days to expiry at entry, one trade per underlying at a time (except Ideas),
sell at the bid / buy at the ask per leg, US$0.10 per contract, judged after 12 months.

| Book | Underlyings | Entry | Exit |
|---|---|---|---|
| **Wheel** (v1) | SPY, IWM | as above | as above |
| **Put credit spread** | SPY, IWM, QQQ | sell the put nearest −0.25 delta (same as the wheel), buy the put nearest −0.10 delta below it | buy back the spread at 50% of the credit, or close at 21 days to expiry whatever its value |
| **Iron condor** | SPY, IWM, QQQ | sell the put nearest −0.16 and the call nearest +0.16 delta; buy the put nearest −0.05 and the call nearest +0.05 | 50% of the credit, or close at 21 days to expiry |
| **Ideas (long calls)** | whatever the nightly scan flags as a dip-buy call | buy 1 contract of each new dip-buy idea at the ask; at most 5 open, at most US$2,000 premium each | sell at +100% (double), at −50%, or at 21 days to expiry |
| **Crash puts** | SPY | buy the put nearest −0.10 delta (≈ 7–10% below spot) | sell it at 21 days to expiry and buy the next month's (a roll); no take-profit, so a crash shows its full payoff at the next roll |

### What each is judged on (after 12 months)

- **Put credit spread vs wheel:** return and worst drawdown side by side. The question:
  is capping the crash risk worth the smaller premium?
- **Iron condor:** return and drawdown vs holding SPY/IWM/QQQ; how often a big move in
  either direction hits it.
- **Ideas:** total return of the calls bought; does the scan pick winners?
- **Crash puts:** the yearly cost of the insurance, and how much it paid in any drop of
  10% or more. On its own it is expected to lose money; the question is what it costs.

## Not now (logged for later)

| Idea | Why not yet | What it would need |
|---|---|---|
| **LEAPS** (long-dated options) | The chain snapshot only stores up to 45 days out | Raise `OptionsChainWorker` `max_days_to_expiry` to ~730 and widen the strike band for those expiries. More quotes stored each night; check Questrade's limits first. |
| **Naked strangles** | Unlimited risk on both sides | Not planned; an iron condor is the defined-risk version. |
| **0DTE** | One snapshot a night can't trade same-day options | Intraday chain data and an intraday engine. |
| **Earnings plays** | No earnings calendar or surprise data | A paid earnings data source (the FMP free plan returns only the last 5 per stock). |
| **Multi-leg orders at Wealthsimple** | Unconfirmed whether Wealthsimple accepts spreads and condors as one order | Check in the app before trading any of these for real. |
