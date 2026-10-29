//! Several strategies backtested together on one account, with the account
//! safety rules applied the way the live engine applies them.
//!
//! Each play brings its own backtest trades. They are replayed in time
//! order on one account that starts at 1.0:
//!
//! - **Sizing** is the live rule: a trade puts `risk_pct / stop distance`
//!   of NAV into the position, capped at the play's notional cap. Its
//!   account return is that share times the trade's return.
//! - **One trade per instrument**, as live: a play can't open on an
//!   instrument another play already holds.
//! - **Risk budget and group cap**: the live check (`AccountLimits::breach`).
//! - **Drawdown pause and circuit breaker** need a person to resume, which a
//!   backtest can't do. They are reported as the dates they would have
//!   tripped, and the replay carries on as if you had resumed at once.
//!
//! Without limits, only the one-per-instrument rule applies: the same plays
//! side by side, to show what the rules cost or saved.

use std::collections::{BTreeMap, HashMap};

use chrono::{DateTime, Duration, NaiveDate, Utc};
use serde::Serialize;

use crate::engine::rules::{AccountLimits, Breach};
use crate::engine::stats::{annual_sharpe_of, daily_returns};
use crate::engine::types::Trade;

/// Points a chart gets at most.
const MAX_POINTS: usize = 240;

/// One strategy in the replay.
#[derive(Debug, Clone)]
pub struct Play {
    pub key: String,
    pub instrument: String,
    /// Share of NAV each trade risks (0.01 = 1%).
    pub risk_pct: f64,
    /// Largest position as a share of NAV (1.5 = 150%).
    pub max_position_pct: f64,
    pub breaker_exempt: bool,
    pub trades: Vec<Trade>,
}

/// The circuit breaker's limits, as Opus runs them.
#[derive(Debug, Clone)]
pub struct Breaker {
    pub losses: usize,
    /// Trade returns summing below minus this over the window (0.08 = 8%).
    pub drawdown: f64,
    pub window_days: i64,
    pub min_trades: usize,
}

#[derive(Debug, Clone)]
pub struct Limits {
    pub account: AccountLimits,
    /// Fall from the peak that pauses trading (0.10 = 10%).
    pub drawdown_pause: f64,
    pub breaker: Breaker,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Blocked {
    pub instrument_busy: usize,
    pub risk_budget: usize,
    pub group_cap: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Trip {
    pub key: String,
    pub at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Point {
    pub time: DateTime<Utc>,
    /// Account return so far (0.05 = +5%).
    pub equity: f64,
    /// How far below its best (≤ 0).
    pub drawdown: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Outcome {
    pub total_return: f64,
    pub annual_return: f64,
    pub max_drawdown: f64,
    pub annual_sharpe: f64,
    pub taken: usize,
    pub blocked: Blocked,
    /// Trades taken per play, by key.
    pub taken_by_play: BTreeMap<String, usize>,
    pub pause_trips: Vec<DateTime<Utc>>,
    pub breaker_trips: Vec<Trip>,
    pub points: Vec<Point>,
    #[serde(skip)]
    pub daily: BTreeMap<NaiveDate, f64>,
}

/// Share of NAV a trade's position takes: the live sizing rule before unit
/// rounding (`live::sizing::compute_units`).
pub fn position_share(risk_pct: f64, max_position_pct: f64, trade: &Trade) -> f64 {
    let distance = (trade.entry_price - trade.stop_price).abs() / trade.entry_price;
    if distance > 0.0 && distance.is_finite() {
        (risk_pct / distance).min(max_position_pct)
    } else {
        max_position_pct
    }
}

struct Open<'a> {
    play: &'a Play,
    trade: &'a Trade,
    nav_at_entry: f64,
}

/// The account as the replay runs.
struct Replay<'a> {
    limits: Option<&'a Limits>,
    nav: f64,
    peak: f64,
    pause_peak: f64,
    max_dd: f64,
    open: Vec<Open<'a>>,
    closed: Vec<(DateTime<Utc>, f64)>,
    points: Vec<Point>,
    pause_trips: Vec<DateTime<Utc>>,
    breaker_trips: Vec<Trip>,
    breakers: HashMap<&'a str, BreakerState>,
}

impl<'a> Replay<'a> {
    /// Close every open trade that exits by `at` (all of them with None),
    /// in exit order.
    fn close_until(&mut self, at: Option<DateTime<Utc>>) {
        self.open.sort_by_key(|o| o.trade.exit_time);
        while self
            .open
            .first()
            .is_some_and(|o| at.is_none_or(|at| o.trade.exit_time <= at))
        {
            let o = self.open.remove(0);
            self.close(o);
        }
    }

    fn close(&mut self, o: Open<'a>) {
        let share = position_share(o.play.risk_pct, o.play.max_position_pct, o.trade);
        let pnl = o.nav_at_entry * share * o.trade.pnl_percent;
        let exit = o.trade.exit_time;
        self.closed.push((exit, pnl / self.nav));
        self.nav += pnl;
        self.peak = self.peak.max(self.nav);
        let drawdown = self.nav / self.peak - 1.0;
        self.max_dd = self.max_dd.min(drawdown);
        self.points.push(Point {
            time: exit,
            equity: self.nav - 1.0,
            drawdown,
        });

        let Some(limits) = self.limits else { return };
        self.pause_peak = self.pause_peak.max(self.nav);
        if self.nav <= self.pause_peak * (1.0 - limits.drawdown_pause) {
            self.pause_trips.push(exit);
            self.pause_peak = self.nav;
        }
        if !o.play.breaker_exempt {
            let state = self.breakers.entry(o.play.key.as_str()).or_default();
            if state.record(o.trade, &limits.breaker) {
                self.breaker_trips.push(Trip {
                    key: o.play.key.clone(),
                    at: exit,
                });
            }
        }
    }

    /// Why `play` can't open now, if it can't.
    fn refusal(&self, play: &Play) -> Option<Refusal> {
        if self
            .open
            .iter()
            .any(|o| o.play.instrument == play.instrument)
        {
            return Some(Refusal::InstrumentBusy);
        }
        let held = self
            .open
            .iter()
            .map(|o| (o.play.instrument.as_str(), o.play.risk_pct));
        match self
            .limits?
            .account
            .breach(&play.instrument, play.risk_pct, held)?
        {
            Breach::GroupCap { .. } => Some(Refusal::GroupCap),
            Breach::RiskBudget { .. } => Some(Refusal::RiskBudget),
        }
    }
}

enum Refusal {
    InstrumentBusy,
    RiskBudget,
    GroupCap,
}

/// Replay `plays` together between `from` and `to` (trades that open in
/// the window), with `limits` or without.
pub fn simulate(
    plays: &[&Play],
    limits: Option<&Limits>,
    from: DateTime<Utc>,
    to: DateTime<Utc>,
) -> Outcome {
    let mut entries: Vec<(usize, &Trade)> = plays
        .iter()
        .enumerate()
        .flat_map(|(i, p)| p.trades.iter().map(move |t| (i, t)))
        .filter(|(_, t)| t.entry_time >= from && t.entry_time <= to)
        .collect();
    entries.sort_by_key(|(i, t)| (t.entry_time, *i));

    let mut replay = Replay {
        limits,
        nav: 1.0,
        peak: 1.0,
        pause_peak: 1.0,
        max_dd: 0.0,
        open: Vec::new(),
        closed: Vec::new(),
        points: vec![Point {
            time: from,
            equity: 0.0,
            drawdown: 0.0,
        }],
        pause_trips: Vec::new(),
        breaker_trips: Vec::new(),
        breakers: HashMap::new(),
    };
    let mut blocked = Blocked::default();
    let mut taken_by_play: BTreeMap<String, usize> = BTreeMap::new();

    for (i, trade) in entries {
        let play = plays[i];
        replay.close_until(Some(trade.entry_time));
        match replay.refusal(play) {
            Some(Refusal::InstrumentBusy) => blocked.instrument_busy += 1,
            Some(Refusal::RiskBudget) => blocked.risk_budget += 1,
            Some(Refusal::GroupCap) => blocked.group_cap += 1,
            None => {
                *taken_by_play.entry(play.key.clone()).or_default() += 1;
                let nav_at_entry = replay.nav;
                replay.open.push(Open {
                    play,
                    trade,
                    nav_at_entry,
                });
            }
        }
    }
    replay.close_until(None);

    let nav = replay.nav;
    let daily = daily_returns(replay.closed, from, to);
    let years = (to - from).num_days().max(1) as f64 / 365.25;
    Outcome {
        total_return: nav - 1.0,
        annual_return: if nav > 0.0 {
            nav.powf(1.0 / years) - 1.0
        } else {
            -1.0
        },
        max_drawdown: replay.max_dd.abs(),
        annual_sharpe: annual_sharpe_of(&daily),
        taken: taken_by_play.values().sum(),
        blocked,
        taken_by_play,
        pause_trips: replay.pause_trips,
        breaker_trips: replay.breaker_trips,
        points: sample(replay.points),
        daily,
    }
}

/// A play's losses since its last (assumed) reset.
#[derive(Default)]
struct BreakerState {
    streak: usize,
    recent: Vec<(DateTime<Utc>, f64)>,
}

impl BreakerState {
    /// Book a closed trade; true when the breaker trips (and resets).
    fn record(&mut self, trade: &Trade, breaker: &Breaker) -> bool {
        self.streak = if trade.pnl_percent < 0.0 {
            self.streak + 1
        } else {
            0
        };
        let window_start = trade.exit_time - Duration::days(breaker.window_days);
        self.recent.retain(|(at, _)| *at >= window_start);
        self.recent.push((trade.exit_time, trade.pnl_percent));
        let sum: f64 = self.recent.iter().map(|(_, r)| r).sum();

        let tripped = self.streak >= breaker.losses
            || (self.recent.len() >= breaker.min_trades && sum < -breaker.drawdown);
        if tripped {
            *self = Self::default();
        }
        tripped
    }
}

/// Pearson correlation of two daily series over the days both have.
/// None with fewer than 20 shared days or a flat series.
pub fn correlation(a: &BTreeMap<NaiveDate, f64>, b: &BTreeMap<NaiveDate, f64>) -> Option<f64> {
    let pairs: Vec<(f64, f64)> = a
        .iter()
        .filter_map(|(day, x)| b.get(day).map(|y| (*x, *y)))
        .collect();
    let n = pairs.len() as f64;
    if pairs.len() < 20 {
        return None;
    }
    let (mx, my) = (
        pairs.iter().map(|p| p.0).sum::<f64>() / n,
        pairs.iter().map(|p| p.1).sum::<f64>() / n,
    );
    let cov: f64 = pairs.iter().map(|(x, y)| (x - mx) * (y - my)).sum();
    let vx: f64 = pairs.iter().map(|(x, _)| (x - mx).powi(2)).sum();
    let vy: f64 = pairs.iter().map(|(_, y)| (y - my).powi(2)).sum();
    (vx > 0.0 && vy > 0.0).then(|| cov / (vx.sqrt() * vy.sqrt()))
}

fn sample(points: Vec<Point>) -> Vec<Point> {
    if points.len() <= MAX_POINTS {
        return points;
    }
    let step = points.len().div_ceil(MAX_POINTS);
    let last = points.len() - 1;
    points
        .into_iter()
        .enumerate()
        .filter(|(i, _)| i % step == 0 || *i == last)
        .map(|(_, p)| p)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::{Direction, EntryReason, ExitReason};
    use chrono::{Datelike, TimeZone};

    fn at(day: u32, hour: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 1, day, hour, 0, 0).unwrap()
    }

    /// A long trade from `open` to `close` (day, hour) returning `pnl`, with
    /// its stop 2% below entry: at 1% risk it takes half the account.
    fn trade(open: (u32, u32), close: (u32, u32), pnl: f64) -> Trade {
        Trade {
            direction: Direction::Long,
            entry_price: 100.0,
            exit_price: 100.0 * (1.0 + pnl),
            entry_time: at(open.0, open.1),
            exit_time: at(close.0, close.1),
            pnl_percent: pnl,
            entry_reason: EntryReason::Indicator {
                name: "test",
                value: 0.0,
            },
            exit_reason: ExitReason::TrendReversal,
            stop_price: 98.0,
        }
    }

    fn play(key: &str, instrument: &str, trades: Vec<Trade>) -> Play {
        Play {
            key: key.into(),
            instrument: instrument.into(),
            risk_pct: 0.01,
            max_position_pct: 1.5,
            breaker_exempt: false,
            trades,
        }
    }

    fn limits(budget: f64, per_group: usize) -> Limits {
        Limits {
            account: AccountLimits {
                risk_budget: budget,
                max_open_per_group: per_group,
                groups: HashMap::from([
                    ("SPX500_USD".to_string(), "index".to_string()),
                    ("NAS100_USD".to_string(), "index".to_string()),
                    ("EU50_EUR".to_string(), "index".to_string()),
                ]),
            },
            drawdown_pause: 0.10,
            breaker: Breaker {
                losses: 3,
                drawdown: 0.08,
                window_days: 30,
                min_trades: 5,
            },
        }
    }

    #[test]
    fn a_trade_is_sized_by_its_stop_like_the_live_engine() {
        let t = trade((5, 10), (5, 12), 0.02);
        assert!((position_share(0.01, 1.5, &t) - 0.5).abs() < 1e-12);
        // A tight stop is capped at the notional limit.
        let tight = Trade {
            stop_price: 99.9,
            ..t
        };
        assert_eq!(position_share(0.01, 1.5, &tight), 1.5);
    }

    #[test]
    fn account_returns_compound_by_position_size() {
        let p = play(
            "a",
            "SPX500_USD",
            vec![trade((5, 10), (5, 12), 0.04), trade((6, 10), (6, 12), 0.04)],
        );
        let out = simulate(&[&p], None, at(5, 0), at(7, 0));
        // Each trade: half the account × 4% = +2%, compounded.
        assert!((out.total_return - (1.02_f64 * 1.02 - 1.0)).abs() < 1e-12);
        assert_eq!(out.taken, 2);
    }

    #[test]
    fn the_group_cap_blocks_a_third_index_trade() {
        let a = play("a", "SPX500_USD", vec![trade((5, 10), (5, 20), 0.01)]);
        let b = play("b", "NAS100_USD", vec![trade((5, 11), (5, 20), 0.01)]);
        let c = play("c", "EU50_EUR", vec![trade((5, 12), (5, 20), 0.01)]);
        let plays = [&a, &b, &c];

        let capped = simulate(&plays, Some(&limits(0.05, 2)), at(5, 0), at(6, 0));
        assert_eq!(capped.taken, 2);
        assert_eq!(capped.blocked.group_cap, 1);

        let free = simulate(&plays, None, at(5, 0), at(6, 0));
        assert_eq!(free.taken, 3);
        assert_eq!(free.blocked, Blocked::default());
    }

    #[test]
    fn the_risk_budget_blocks_a_trade_that_would_go_over() {
        let a = play("a", "SPX500_USD", vec![trade((5, 10), (5, 20), 0.01)]);
        let b = play("b", "NAS100_USD", vec![trade((5, 11), (5, 20), 0.01)]);
        let out = simulate(&[&a, &b], Some(&limits(0.015, 5)), at(5, 0), at(6, 0));
        assert_eq!(out.blocked.risk_budget, 1);
        assert_eq!(out.taken_by_play.get("a"), Some(&1));
        assert_eq!(out.taken_by_play.get("b"), None);
    }

    #[test]
    fn two_plays_cannot_hold_the_same_instrument() {
        let daily = play("d", "NAS100_USD", vec![trade((5, 10), (7, 20), 0.01)]);
        let intraday = play("m", "NAS100_USD", vec![trade((6, 14), (6, 20), 0.01)]);
        let out = simulate(&[&daily, &intraday], None, at(5, 0), at(8, 0));
        assert_eq!(out.blocked.instrument_busy, 1);
        assert_eq!(out.taken, 1);
    }

    #[test]
    fn the_breaker_trip_is_reported_and_the_replay_carries_on() {
        let losers = (5..9).map(|d| trade((d, 10), (d, 12), -0.01)).collect();
        let p = play("a", "SPX500_USD", losers);
        let out = simulate(&[&p], Some(&limits(0.05, 2)), at(5, 0), at(10, 0));
        assert_eq!(out.breaker_trips.len(), 1);
        assert_eq!(out.breaker_trips[0].at, at(7, 12));
        // The fourth trade still happens: you'd have resumed.
        assert_eq!(out.taken, 4);

        let exempt = Play {
            breaker_exempt: true,
            ..p
        };
        let out = simulate(&[&exempt], Some(&limits(0.05, 2)), at(5, 0), at(10, 0));
        assert!(out.breaker_trips.is_empty());
    }

    #[test]
    fn the_drawdown_pause_trips_at_ten_percent_below_the_peak() {
        // Each loss: half the account × −8% = −4% of NAV.
        let losers = (5..9).map(|d| trade((d, 10), (d, 12), -0.08)).collect();
        let p = Play {
            breaker_exempt: true,
            ..play("a", "SPX500_USD", losers)
        };
        let out = simulate(&[&p], Some(&limits(0.05, 2)), at(5, 0), at(10, 0));
        // 0.96, 0.9216, 0.8847: the third loss is 11.5% below the start.
        assert_eq!(out.pause_trips, vec![at(7, 12)]);
        assert!((out.max_drawdown - (1.0 - 0.96_f64.powi(4))).abs() < 1e-12);
    }

    #[test]
    fn correlation_reads_together_opposite_and_too_short() {
        let days: Vec<NaiveDate> = (0..30)
            .map(|i| NaiveDate::from_ymd_opt(2026, 1, 1).unwrap() + Duration::days(i))
            .collect();
        let a: BTreeMap<_, _> = days
            .iter()
            .map(|d| (*d, (d.ordinal() % 7) as f64))
            .collect();
        let neg: BTreeMap<_, _> = a.iter().map(|(d, v)| (*d, -v)).collect();
        assert!((correlation(&a, &a).unwrap() - 1.0).abs() < 1e-12);
        assert!((correlation(&a, &neg).unwrap() + 1.0).abs() < 1e-12);

        let short: BTreeMap<_, _> = a.iter().take(10).map(|(d, v)| (*d, *v)).collect();
        assert_eq!(correlation(&a, &short), None);
    }
}
