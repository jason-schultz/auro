# Research round 3: stress signals from outside the price

Written 2026-10-26, **before any results were computed**. Signals, rules, data and pass
criteria are fixed here; one look, no re-tuning. (Rules: `decision_lockbox_protocol`;
round 2 is `round2_preregistration.md`.)

## Question

Do measurable signs of real-world stress, rather than price trends, flag the big bear
markets early enough to matter, without crying wolf on the scares that stayed contained?

Round 2 showed price trend is too slow for crash-and-recover (Covid) and too noisy in
calm years. The user's read: the crises that hit the US and Canada hard (dot-com,
2008) started in the US financial system, where the dollar sits at the centre, while
foreign scares (euro debt 2011, China 2015, Brexit 2016) stayed mostly contained.
So the signals are US-centric, and the scares are reported to test that read.

## Signals (each judged on its own, plus one combination)

| Signal | Data | On | Off | Lag |
|---|---|---|---|---|
| **Credit** | Moody's Baa corporate yield minus 10-year Treasury (FRED `BAA10Y`, daily, 1986–) | spread ≥ 2 standard deviations above its trailing 252-day mean | spread back at or below that mean | 1 day (published next day) |
| **Fear** | VIX close (Yahoo `^VIX`, 1990–) | VIX > 30 | VIX < 20 | none (end-of-day close) |
| **Recession** | Real-time Sahm rule (FRED `SAHMREALTIME`, monthly, as first published) | ≥ 0.50 (Sahm's own threshold) | < 0.50 | usable from the 10th of the following month |
| **Two of three** | the three above | at least two on | fewer than two on | — |

Between "on" and "off" a signal keeps its last state. Thresholds are the conventional
ones (2σ, VIX 30/20, Sahm 0.5), not fitted.

## What a signal does

- **De-risk:** hold the index when the signal is off, sit in cash when it's on.
- **Short:** short the index while the signal is on (reported separately).

A signal is read at the day's close and acted on at the next day's close.
Index: **S&P 500** for the criteria; the **TSX** is reported alongside.

Costs: 2 bp per switch; dividends estimated at 2.0%/yr (S&P) and 2.7%/yr (TSX), earned
when long and paid when short; cash earns nothing and CFD financing is left out. Both
of those simplifications favour holding over switching, so they work against the
signal.

Test period: 1991-01-01 → now (every series has a year of history by then).

## Crash windows and contained scares

Crashes (S&P peak to trough): dot-com 2000-03-24 → 2002-10-09; housing 2007-10-09 →
2009-03-09; Covid 2020-02-19 → 2020-03-23; 2022 bear 2022-01-03 → 2022-10-12.

Contained scares (reported, not scored): Asia 1997-10, LTCM/Russia 1998-08,
euro debt 2011-07 → 2011-10, China 2015-08 → 2016-02, Brexit 2016-06, late 2018
(2018-10 → 2018-12), SVB 2023-03.

## Pass criteria for de-risking (all must hold)

1. **Avoids the crashes.** In each of the four crash windows the de-risked index loses
   at least 25% less than buy-and-hold.
2. **Worth it overall.** Over the whole period its Sharpe is at least buy-and-hold's,
   and its worst drawdown is no more than two-thirds of buy-and-hold's.

## Short side (separate verdict)

Shorting while a signal is on is allowed only if the short returns are positive in
total across all its episodes **and** positive in at least three of the four crash
windows.

## Note on luck

Four signals are tested, so one passing by chance is possible. A pass should be clear,
not marginal, and it would still need forward evidence before it switches anything live.

## If something passes

Turn it into an Opus signal that pauses the long index strategies (and, if the short
verdict passes, opens a small index short), shown on the Strategies page, and log every
flip in the Research tab. If nothing passes, record it and move to the manual crisis
switch, currently on the back burner.

## Result (2026-10-26): FAIL, all four signals

Run once with `cargo run --release --example stress_signals`
(`auro_be/examples/stress_signals.rs`); full output in
`research/results/round3_stress_signals.json`. Nothing was changed after the look. (FRED
refused the Rust client, so its two CSVs were cached with curl from the same URLs.)

S&P 500, 1991 → 2026. Buy-and-hold: Sharpe 0.69, worst drawdown −55.5%.

| Signal | dot-com | 2008 | Covid | 2022 | Sharpe | Worst DD | Short total |
|---|---|---|---|---|---|---|---|
| Buy-and-hold | −46.5% | −55.5% | −33.8% | −24.3% | 0.69 | −55.5% | |
| Credit | −43.8% | **0.0%** | −11.3% | −21.5% | 0.70 | −47.1% | −83% |
| Fear (VIX) | −40.6% | −30.0% | −12.0% | −33.4% | 0.53 | −41.5% | −93% |
| Recession (Sahm) | **−20.6%** | **−9.3%** | −33.8% | −24.3% | **0.74** | **−33.8%** | −53% |
| Two of three | −39.0% | −18.2% | −11.3% | −31.3% | 0.69 | −42.1% | −82% |

(Rows show the de-risked index; buy-and-hold first.)

- **No signal avoided all four crashes**, so all fail criterion 1. 2022 (an inflation and
  Fed bear with no recession) beat every signal; VIX and two-of-three did worse than
  holding there.
- **Shorting failed everywhere.** Even the signals that made +50–80% short in 2008 lost
  53–93% overall, because they stay on into the recovery rallies. Avoiding the crash
  pays; betting on it doesn't.
- **The user's "contained scares" read held up for the recession signal.** Sahm was quiet
  through all seven contained scares (1997, 1998, 2011, 2015–16, Brexit, 2018, SVB), and
  it cut the two US-born bear markets by 56% and 83%. Since 1991 it switched on only
  four times: 2001, 2008, 2020 (in April, *after* the Covid bottom, so it then sat out
  the rebound) and July–Sept 2024 (a false alarm). It passed criterion 2 but not 1:
  too slow for Covid, and blind to 2022.
- **Credit spreads cried wolf** in 1998, 2015 and 2018, and the VIX in nearly every
  scare, so neither tells contained scares from real ones.
- **TSX** (reported only): the same pattern; recession and two-of-three de-risking
  improved its Sharpe (0.75, 0.81 vs 0.67).

The pattern "recession signal for slow US bears, something faster for crashes" is a
**new hypothesis formed after looking**, not a result. It can't be validated on this
history again, and a signal that fires every eight years can't be forward-tested
quickly. Its natural home is the manual crisis switch (back burner), as one of the
documented triggers the user weighs.
