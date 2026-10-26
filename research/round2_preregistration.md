# Research round 2: a two-sided trend book

Written 2026-10-26, **before any results were computed**. The spec, universe, costs and
pass criteria below are fixed. If the result fails, the idea fails; nothing gets
re-tuned after the look. (Same rule as the October lockbox, see `decision_lockbox_protocol`.)

## Goal

Strategies that ride the wave in either direction, and in particular a short side that
pays in market crashes: dot-com 2000–02, the housing crisis 2008, Covid 2020, the 2022
bear market. This sits alongside the live long-biased index strategies (RSI(2) dip-buy,
NAS100 noise-area). It is not meant to replace them.

## What we already know (and why the bar is "crisis insurance", not "high Sharpe")

| Earlier result | Source |
|---|---|
| Trend on FX and indices, 2017–24, net of costs: dead | Oct 16 sweep |
| Bond 12-month trend: Sharpe +0.21 exploring, **−1.17 in the lockbox** | Oct 17 lockbox |
| Turtle 20/10 and 55/20 on 12 commodities/metals, daily: dead | Oct 13 screen |
| Shorting index rips below the 200-day MA: wins only 2022, loses −111% in 2020 | Jun 2 test |

Trend following had a famously weak 2010s, and OANDA CFD financing (≈2.5% markup on
indices and commodities, energy financed off the futures basis) makes holding it worse.
So the expectation in calm years is a **small loss**, not a profit. The case for it is
that trend books have historically made money in prolonged crashes, exactly when the
long index strategies lose. That is what gets tested.

## The one candidate

**Trend book, from Hurst, Ooi & Pedersen (2017), "A Century of Evidence on
Trend-Following Investing".** Published spec, no parameter search:

- **Signal**, per instrument at each month-end: the sign of the past 1-, 3- and
  12-month return, averaged. The position is therefore one of
  −1, −⅓, +⅓, +1 (fully short … fully long).
- **Sizing:** each instrument scaled to the same expected volatility (the paper's
  volatility targeting), the book sized to 10% annual volatility.
- **Rebalance:** monthly, at the month-end close.
- **Universe:** every active OANDA instrument with daily history: indices, FX, metals,
  energy, agriculture, bonds. Nothing is dropped for looking bad (UK100 stays in).

The 1- and 3-month signals are what give it a chance in fast crashes; the 12-month
signal alone flips short too late for Covid.

## How it gets tested

1. **OANDA history, 2010 → now, all instruments**, with the real cost model (spread and
   the Rust backtest's financing model, overridden by recorded OANDA rates where we
   have them). *Amended 2026-10-26, before any result was computed:* the window was
   2017 → now, but stored daily bars only started in 2018 and the 12-month signal needs
   a year of warm-up, which would have left four calm years. Daily bars were backfilled
   to 2010 through Auro. Policy rates start in 2016, so 2010–15 financing is the markup
   only (rates were near zero for most currencies then).
2. **Crash test on long index history, 1990 → now.** OANDA data doesn't reach 2000 or
   2008, so the index part also runs on long daily index history (S&P 500, Nasdaq 100,
   Dow, DAX, Euro Stoxx 50, FTSE, Nikkei, ASX 200) with costs estimated at the OANDA
   levels. This is only to see crisis behaviour; it is not a second chance to pass.
3. Reported both for the whole book and with indices broken out, plus with the
   three biggest contributing instruments removed (a portfolio edge must survive that).

## Pass criteria (all must hold)

1. **Pays in crashes.** Positive return in each crisis window on the long index
   history: 2000-09 → 2002-10, 2007-10 → 2009-03, 2020-02 → 2020-04, 2022-01 → 2022-10.
2. **Cheap in calm years.** Average loss in non-crisis years no worse than **−3% a year**
   at 10% book volatility.
3. **Actually hedges.** Correlation with the live long sleeves (RSI(2) dip-buy and
   noise-area) is zero or negative over their losing months.
4. **Not a few lucky instruments.** Criteria 1–3 still hold with the top three
   contributors removed.

## If it passes

Build it into Auro: a trend-signal component, a monthly rebalance, volatility-target
sizing and long/short flips. Then forward-test on the practice account for at least
six months. Daily trend trades too rarely for six months to prove anything
statistically. The forward test checks that live fills, costs and signals match the
backtest; the evidence for the edge itself is the century of published data plus
criterion 1.

## If it fails

Record it as dead and don't revisit it on this data. The short side for crashes would
then need a different idea, such as a crash-versus-grind detector or index put options.

## Result (2026-10-26): FAIL

Run once with `cargo run --release --example trend_book` (`auro_be/examples/trend_book.rs`);
full output in `research/results/round2_trend_book.json`. No parameter was changed after
the look. One diagnostic was added afterwards (the same books with no costs), which
doesn't affect the verdict.

| Criterion | Result | |
|---|---|---|
| 1. Pays in crashes (long index history) | dot-com +7.8%, 2008 +9.0%, Covid −3.4%, 2022 −13.3% | FAIL |
| 2. Calm-year cost (OANDA book, 2011–26) | −7.6% a year against a −3% floor | FAIL |
| 3. Hedges the long sleeves | correlation −0.37 over their 63 losing months | PASS |
| 4. Without the top three contributors | Covid and 2022 still negative; calm years −8.8% | FAIL |

- **Crashes:** monthly trend caught the two slow bear markets, 2000–02 and 2008. It lost in
  Covid, which fell and recovered within two months, and in 2022, where bear-market
  rallies flipped it back and forth.
- **Costs:** on OANDA the book's Sharpe was −0.59 net and −0.07 gross. Most of the gap is
  financing. Volatility targeting puts large notional on low-volatility instruments such
  as the 2-year bond CFD, and OANDA's ~2.5% markup applies to that notional. The paper
  used futures, which have no markup. Bonds alone cost −33.6% over the period.
- **Hedge:** it did move against the long sleeves in their bad months (−0.37), but its
  average return in those months was −0.1%, so it didn't earn anything there either.

Recorded as dead on this data. Not to be retried as a CFD implementation.
