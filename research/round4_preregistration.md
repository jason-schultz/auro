# Research round 4: volatility-managed index exposure

Written 2026-10-26, **before any results were computed**. One look, no re-tuning.

## Why

Rounds 2 and 3 found that avoiding crashes pays and shorting them doesn't, and that the
slow signals (trend, recession) miss fast crashes like Covid. Volatility reacts within
days. Moreira & Muir (2017), "Volatility-Managed Portfolios", show that holding less of
the market when recent volatility is high raised Sharpe ratios across equity factors,
because high volatility isn't followed by proportionally higher returns.

## Spec (the paper's, made long-only)

- At each month-end close, measure the realized variance of the index's daily returns
  over that month (annualized ×252).
- Exposure for the next month = min(1, 0.16² ÷ realized variance). 16% is the S&P 500's
  long-run volatility, a conventional figure, not fitted. Exposure never goes above 1
  (no leverage: TFSA and CFD-friendly), so in calm months it is fully invested and in
  turbulent months it scales down.
- The rest sits in cash, earning nothing.

The paper allowed leverage; capping at 1 is a deliberate, stated deviation so the result
is something the user could actually run.

## Test

Same harness, data, costs and windows as round 3, so the results compare directly:
S&P 500 scored, TSX reported; 1991 → now; 2 bp per unit of exposure traded; dividends
2.0% / 2.7% on the invested part; crash windows dot-com, 2008, Covid, 2022; the same
seven contained scares reported.

## Pass criteria (identical to round 3's de-risk criteria)

1. **Avoids the crashes.** In each crash window it loses at least 25% less than
   buy-and-hold.
2. **Worth it overall.** Sharpe at least buy-and-hold's, and worst drawdown no more than
   two-thirds of buy-and-hold's.

## If it passes

Build exposure scaling into Auro as a sizing input for the long index strategies, and
use it as the rule for the user's own index holdings. Forward-check that the live
calculation matches the backtest month by month.

## Result (2026-10-26): FAIL, by a hair

Run once with `cargo run --release --example vol_managed`
(`auro_be/examples/vol_managed.rs`, sharing `examples/common/index_eval.rs` with round 3,
which reproduced round 3's numbers exactly after the refactor); full output in
`research/results/round4_vol_managed.json`. Nothing was changed after the look.

S&P 500, 1991 → 2026:

| | dot-com | 2008 | Covid | 2022 | Sharpe | Worst drawdown |
|---|---|---|---|---|---|---|
| Buy-and-hold | −46.5% | −55.5% | −33.8% | −24.3% | 0.69 | −55.5% |
| Volatility-managed | −32.4% | −25.8% | −21.4% | −17.0% | **0.82** | −37.2% |

- **Criterion 1 passed:** it lost at least 25% less in all four crashes, the first rule
  in any round to do so, including Covid and 2022, which beat every round 3 signal.
- **Criterion 2 failed by 0.2 points:** Sharpe rose from 0.69 to 0.82, but the worst
  drawdown, −37.2%, missed the two-thirds bar (−37.0%) by 0.2 percentage points.
- Average exposure 86%; fully invested two days in three.
- **Scares:** it did slightly worse than holding in LTCM 1998 (−12.6% vs −6.1%), the
  euro crisis and China: it de-risked after the drop and was light for the rebound.
- **TSX** (reported): Sharpe 0.67 → 0.77, worst drawdown −48.8% → −36.1%; little help
  in Covid because TSX volatility in February 2020 was still low at the month-end.

By the rule fixed beforehand this is a FAIL. One point is relevant for the user's
decision and was true before the look: the published paper's data ends around 2015,
so 2016–2026 here, including Covid and 2022, is out of sample for the paper's claim,
and it held up there.

**Adopted 2026-10-26 by the user** despite the 0.2-point miss on criterion 2. Used as
it was tested: a monthly exposure figure for holding the S&P 500 (shown on the Accounts
page, `Opus.Accounts.IndexExposure`). It is **not** wired into the sizing of Auro's
strategies: the RSI(2) dip-buy enters right after drops, when volatility is high, so
scaling it down by volatility is a different, untested rule that could cut its best
trades. That would need its own test first.
