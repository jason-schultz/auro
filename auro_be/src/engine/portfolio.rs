//! Several strategies backtested together on one account, with the account
//! safety rules applied the way the live engine applies them.
//!
//! Each play brings its own backtest trades. They are replayed in time
//! order on one account that starts at 1.0:
//!
//! - **Sizing** is the live rule: a trade puts `risk_pct / stop distance`
//!   of NAV into the position, capped at the play's notional cap. Its
//!   account return is that share times the trade's return.
//! - **One trade per play**, as live: a strategy holds one position at a
//!   time, but two strategies may hold the same instrument at once (live
//!   checks open positions per strategy, not per instrument).
//! - **Risk budget and group cap**: the live check (`AccountLimits::breach`).
//! - **Valued every bar**: open trades count at each bar's close
//!   (`mark_return`), on one clock across every market, so the drawdown,
//!   the chart and the drawdown pause see a dip that recovers before the
//!   trade closes.
//! - **Drawdown pause and circuit breaker** need a person to resume, which a
//!   backtest can't do. They are reported as the dates they would have
//!   tripped, and the replay carries on as if you had resumed at once.
//!
//! Without limits, the same plays run side by side unchecked, to show what
//! the rules cost or saved.

use std::collections::{BTreeMap, HashMap};

use chrono::{DateTime, Datelike, Duration, NaiveDate, Utc, Weekday};
use serde::Serialize;

use crate::engine::rules::{AccountLimits, Breach};
use crate::engine::stats::annual_sharpe_of;
use crate::engine::types::{Candle, Direction, Trade};

/// Points a chart gets at most.
const MAX_POINTS: usize = 240;

/// One strategy in the replay.
#[derive(Debug, Clone)]
pub struct Play<'a> {
    pub key: String,
    pub instrument: String,
    /// Share of NAV each trade risks (0.01 = 1%).
    pub risk_pct: f64,
    /// Largest position as a share of NAV (1.5 = 150%).
    pub max_position_pct: f64,
    pub breaker_exempt: bool,
    pub trades: Vec<Trade>,
    /// The bars its trades were made on, oldest first. An open trade is
    /// valued at each of their closes (`mark_return`); with none, it counts
    /// at its entry price until it closes.
    pub bars: &'a [Candle],
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
    /// Account return so far, open trades valued at this bar (0.05 = +5%).
    pub equity: f64,
    /// How far below its best (≤ 0).
    pub drawdown: f64,
}

/// A trade the account took, and what it did to the account.
#[derive(Debug, Clone)]
pub struct Fill {
    pub key: String,
    pub trade: Trade,
    /// Its gain or loss as a share of the account just before it closed.
    pub account_return: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Outcome {
    pub total_return: f64,
    pub annual_return: f64,
    /// The account's worst fall from its high (≥ 0), valued at every bar:
    /// open trades count at that bar's close (`mark_return`), so a trade
    /// that dips and recovers before it closes shows its dip.
    pub max_drawdown: f64,
    pub annual_sharpe: f64,
    pub taken: usize,
    pub blocked: Blocked,
    /// Trades taken per play, by key.
    pub taken_by_play: BTreeMap<String, usize>,
    pub pause_trips: Vec<DateTime<Utc>>,
    pub breaker_trips: Vec<Trip>,
    pub points: Vec<Point>,
    /// The account's return each weekday from `from` to `to` (0.01 =
    /// +1%), open trades valued at each day's last bar, a weekend's moves
    /// on Monday: the Sharpe and how plays move together are read from it,
    /// so a trade's ups and downs land on the days they happen, not all on
    /// the day it closes. Dated, so two plays' days line up.
    #[serde(skip)]
    pub daily: BTreeMap<NaiveDate, f64>,
    /// Every trade taken, in the order they closed.
    #[serde(skip)]
    pub fills: Vec<Fill>,
    /// The worst fall (≥ 0) with every trade on a whole account and added
    /// up rather than sized and compounded (`BacktestStats::max_drawdown`),
    /// valued at every bar the same way.
    #[serde(skip)]
    pub summed_max_drawdown: f64,
    /// The account's return each calendar month (0.01 = +1%), from the
    /// month of its first trade to its last bar, open trades valued at each
    /// month's last bar. A month it held nothing is a 0.
    #[serde(skip)]
    pub monthly: Vec<f64>,
    /// The account's return each trading day (0.01 = +1%), from the day of
    /// its first trade to its last bar, open trades valued at each day's
    /// last bar: what Monte Carlo redraws (`pipeline::run_monte_carlo`).
    /// Every weekday counts, a day it held nothing (or had no bar) as a 0;
    /// a weekend's moves (FX opens Sunday evening) land on Monday.
    #[serde(skip)]
    pub daily_valued: Vec<f64>,
    /// Beside each of `daily_valued`, the day's lowest value over the
    /// day before's close (≤ the day's return): an intraday strategy's dip
    /// that recovers by the day's last bar. Monte Carlo redraws the two as
    /// a pair, so its drawdowns see the dip as the backtest's do. Equal to
    /// `daily_valued` for daily bars (one mark a day).
    #[serde(skip)]
    pub daily_lows: Vec<f64>,
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

/// What `trade` is worth at `bar`'s close, as a return on its position:
/// the price it would close at then (the bid for a long, the ask for a
/// short, as its exit fills) against its entry, plus the financing it has
/// run up so far. The backtest charges a trade's financing when it closes
/// (`apply_costs`), so the part run up is that charge spread evenly
/// over the trade's life (the daily rate barely moves within one trade).
///
/// This is the standard daily mark-to-market: the bar's close, not its
/// low, so a dip inside a bar that's gone by the close doesn't count. At
/// or before the entry bar it's 0; at or after the exit it's the trade's
/// own return.
pub fn mark_return(trade: &Trade, bar: &Candle) -> f64 {
    if bar.time >= trade.exit_time {
        return trade.pnl_percent;
    }
    if bar.time <= trade.entry_time {
        return 0.0;
    }
    let price_return = |price: f64| match trade.direction {
        Direction::Long => (price - trade.entry_price) / trade.entry_price,
        Direction::Short => (trade.entry_price - price) / trade.entry_price,
    };
    let financing = trade.pnl_percent - price_return(trade.exit_price);
    let life = (trade.exit_time - trade.entry_time).num_seconds() as f64;
    let held = (bar.time - trade.entry_time).num_seconds() as f64;
    price_return(bar.exit_fill_price(trade.direction)) + financing * held / life
}

struct Open<'a> {
    play: &'a Play<'a>,
    trade: &'a Trade,
    share: f64,
    nav_at_entry: f64,
    /// The first of its play's bars after the last one it was valued at.
    next_bar: usize,
}

impl Open<'_> {
    /// Its value at `at` as a return on its position: at the close of its
    /// play's latest bar by then (`mark_return`).
    fn mark(&mut self, at: DateTime<Utc>) -> f64 {
        let bars = self.play.bars;
        while bars.get(self.next_bar).is_some_and(|b| b.time <= at) {
            self.next_bar += 1;
        }
        self.next_bar
            .checked_sub(1)
            .map_or(0.0, |i| mark_return(self.trade, &bars[i]))
    }
}

/// The account as the replay runs.
struct Replay<'a> {
    limits: Option<&'a Limits>,
    /// Closed trades only.
    nav: f64,
    /// The highest valued NAV so far.
    peak: f64,
    pause_peak: f64,
    max_dd: f64,
    /// Closed trades' returns added up, each on a whole account.
    summed: f64,
    summed_peak: f64,
    summed_max_dd: f64,
    open: Vec<Open<'a>>,
    closed: Vec<Fill>,
    points: Vec<Point>,
    pause_trips: Vec<DateTime<Utc>>,
    breaker_trips: Vec<Trip>,
    breakers: HashMap<&'a str, BreakerState>,
    first_entry: Option<DateTime<Utc>>,
    /// The valued NAV at the last mark of each (year, month).
    month_ends: BTreeMap<(i32, u32), f64>,
    /// The valued NAV at the last mark of each UTC day.
    day_ends: BTreeMap<NaiveDate, f64>,
    /// The lowest valued NAV marked on each UTC day.
    day_lows: BTreeMap<NaiveDate, f64>,
}

impl<'a> Replay<'a> {
    fn open(&mut self, play: &'a Play<'a>, trade: &'a Trade) {
        self.first_entry.get_or_insert(trade.entry_time);
        let next_bar = play.bars.partition_point(|b| b.time <= trade.entry_time);
        self.open.push(Open {
            play,
            trade,
            share: position_share(play.risk_pct, play.max_position_pct, trade),
            nav_at_entry: self.nav,
            next_bar,
        });
    }

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
        let pnl = o.nav_at_entry * o.share * o.trade.pnl_percent;
        self.closed.push(Fill {
            key: o.play.key.clone(),
            trade: *o.trade,
            account_return: pnl / self.nav,
        });
        // An account that loses everything stays at nothing.
        self.nav = (self.nav + pnl).max(0.0);
        self.summed += o.trade.pnl_percent;

        let Some(limits) = self.limits else { return };
        if !o.play.breaker_exempt {
            let state = self.breakers.entry(o.play.key.as_str()).or_default();
            if state.record(o.trade, &limits.breaker) {
                self.breaker_trips.push(Trip {
                    key: o.play.key.clone(),
                    at: o.trade.exit_time,
                });
            }
        }
    }

    /// Value the account at `at`: closed trades plus every open one at its
    /// market's latest close. The drawdowns, the chart, the month ends and
    /// the drawdown pause (live watches NAV, open trades included) all
    /// read this.
    fn mark(&mut self, at: DateTime<Utc>) {
        let mut nav = self.nav;
        let mut summed = self.summed;
        for o in &mut self.open {
            let r = o.mark(at);
            nav += o.nav_at_entry * o.share * r;
            summed += r;
        }
        let nav = nav.max(0.0);

        self.peak = self.peak.max(nav);
        let drawdown = nav / self.peak - 1.0;
        self.max_dd = self.max_dd.min(drawdown);
        self.summed_peak = self.summed_peak.max(summed);
        self.summed_max_dd = self
            .summed_max_dd
            .min((summed - self.summed_peak) / (1.0 + self.summed_peak));
        self.points.push(Point {
            time: at,
            equity: nav - 1.0,
            drawdown,
        });
        self.month_ends.insert((at.year(), at.month()), nav);
        self.day_ends.insert(at.date_naive(), nav);
        self.day_lows
            .entry(at.date_naive())
            .and_modify(|low| *low = low.min(nav))
            .or_insert(nav);

        let Some(limits) = self.limits else { return };
        self.pause_peak = self.pause_peak.max(nav);
        if nav <= self.pause_peak * (1.0 - limits.drawdown_pause) {
            self.pause_trips.push(at);
            self.pause_peak = nav;
        }
    }

    /// Calendar-month returns from the month of the first trade
    /// (`Outcome::monthly`).
    fn monthly(&self) -> Vec<f64> {
        let Some(first) = self.first_entry else {
            return Vec::new();
        };
        let Some((&last, _)) = self.month_ends.last_key_value() else {
            return Vec::new();
        };
        let mut month = (first.year(), first.month());
        let mut prev = self
            .month_ends
            .range(..month)
            .next_back()
            .map_or(1.0, |(_, nav)| *nav);
        let mut out = Vec::new();
        while month <= last {
            let nav = self.month_ends.get(&month).copied().unwrap_or(prev);
            out.push(if prev > 0.0 { nav / prev - 1.0 } else { 0.0 });
            prev = nav;
            month = match month {
                (y, 12) => (y + 1, 1),
                (y, m) => (y, m + 1),
            };
        }
        out
    }

    /// Trading-day returns from the day of the first trade
    /// (`Outcome::daily_valued`): each weekday's last valued NAV over the
    /// one before, and beside it the lowest valued NAV since then over the
    /// same (`Outcome::daily_lows`). A weekend's marks roll into Monday,
    /// and a run whose last mark falls on a weekend ends with that move.
    fn daily_valued(&self) -> (Vec<f64>, Vec<f64>) {
        let Some(first) = self.first_entry else {
            return (Vec::new(), Vec::new());
        };
        let Some((&last, &last_nav)) = self.day_ends.last_key_value() else {
            return (Vec::new(), Vec::new());
        };
        let mut day = first.date_naive();
        let mut prev = self
            .day_ends
            .range(..day)
            .next_back()
            .map_or(1.0, |(_, nav)| *nav);
        let change = |prev: f64, nav: f64| if prev > 0.0 { nav / prev - 1.0 } else { 0.0 };
        let (mut out, mut lows) = (Vec::new(), Vec::new());
        let mut low = f64::INFINITY;
        while day <= last {
            if let Some(l) = self.day_lows.get(&day) {
                low = low.min(*l);
            }
            if !matches!(day.weekday(), Weekday::Sat | Weekday::Sun) {
                let nav = self.day_ends.get(&day).copied().unwrap_or(prev);
                out.push(change(prev, nav));
                lows.push(change(prev, low.min(nav)));
                prev = nav;
                low = f64::INFINITY;
            }
            day += Duration::days(1);
        }
        if last_nav != prev {
            out.push(change(prev, last_nav));
            lows.push(change(prev, low.min(last_nav)));
        }
        (out, lows)
    }

    /// Each weekday's valued return from `from` to `to` (`Outcome::daily`):
    /// the NAV at the day's last mark (or the last before it, so a
    /// weekend's marks land on Monday) over the day before's. Moves marked
    /// after the last weekday join it.
    fn daily_dated(&self, from: DateTime<Utc>, to: DateTime<Utc>) -> BTreeMap<NaiveDate, f64> {
        let nav_by = |day: NaiveDate| {
            self.day_ends
                .range(..=day)
                .next_back()
                .map_or(1.0, |(_, nav)| *nav)
        };
        let change = |prev: f64, nav: f64| if prev > 0.0 { nav / prev - 1.0 } else { 0.0 };
        let (mut day, last) = (from.date_naive(), to.date_naive());
        let mut prev = nav_by(day - Duration::days(1));
        let mut out = BTreeMap::new();
        while day <= last {
            if !matches!(day.weekday(), Weekday::Sat | Weekday::Sun) {
                let nav = nav_by(day);
                out.insert(day, change(prev, nav));
                prev = nav;
            }
            day += Duration::days(1);
        }
        let end = nav_by(last);
        if let Some(r) = out
            .values_mut()
            .next_back()
            .filter(|_| end != prev && prev > 0.0)
        {
            *r = (1.0 + *r) * (end / prev) - 1.0;
        }
        out
    }

    /// Why `play` can't open now, if it can't.
    fn refusal(&self, play: &Play) -> Option<Refusal> {
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
    RiskBudget,
    GroupCap,
}

/// Replay `plays` together between `from` and `to` (trades that open in
/// the window), with `limits` or without.
///
/// The account is valued on one shared clock: every bar of every play
/// from `from` until the last trade closes, plus each entry and exit. At
/// each moment trades open and close first, then every open trade is
/// valued at its own market's latest close, so markets whose bars don't
/// line up (a holiday, a different session) are each valued at their
/// newest price.
pub fn simulate<'a>(
    plays: &[&'a Play<'a>],
    limits: Option<&'a Limits>,
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

    let until = entries
        .iter()
        .map(|(_, t)| t.exit_time)
        .max()
        .map_or(to, |last| last.max(to));
    let mut clock: Vec<DateTime<Utc>> = plays
        .iter()
        .flat_map(|p| p.bars.iter().map(|b| b.time))
        .filter(|at| *at >= from && *at <= until)
        .chain(
            entries
                .iter()
                .flat_map(|(_, t)| [t.entry_time, t.exit_time]),
        )
        .chain([from])
        .collect();
    clock.sort_unstable();
    clock.dedup();

    let mut replay = Replay {
        limits,
        nav: 1.0,
        peak: 1.0,
        pause_peak: 1.0,
        max_dd: 0.0,
        summed: 0.0,
        summed_peak: 0.0,
        summed_max_dd: 0.0,
        open: Vec::new(),
        closed: Vec::new(),
        points: Vec::with_capacity(clock.len()),
        pause_trips: Vec::new(),
        breaker_trips: Vec::new(),
        breakers: HashMap::new(),
        first_entry: None,
        month_ends: BTreeMap::new(),
        day_ends: BTreeMap::new(),
        day_lows: BTreeMap::new(),
    };
    let mut blocked = Blocked::default();
    let mut taken_by_play: BTreeMap<String, usize> = BTreeMap::new();

    let mut next = entries.into_iter().peekable();
    for &at in &clock {
        while let Some((i, trade)) = next.next_if(|(_, t)| t.entry_time <= at) {
            let play = plays[i];
            replay.close_until(Some(trade.entry_time));
            match replay.refusal(play) {
                Some(Refusal::RiskBudget) => blocked.risk_budget += 1,
                Some(Refusal::GroupCap) => blocked.group_cap += 1,
                None => {
                    *taken_by_play.entry(play.key.clone()).or_default() += 1;
                    replay.open(play, trade);
                }
            }
        }
        replay.close_until(Some(at));
        replay.mark(at);
    }

    let nav = replay.nav;
    let daily = replay.daily_dated(from, to);
    let years = (to - from).num_days().max(1) as f64 / 365.25;
    let monthly = replay.monthly();
    let (daily_valued, daily_lows) = replay.daily_valued();
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
        fills: replay.closed,
        summed_max_drawdown: replay.summed_max_dd.abs(),
        monthly,
        daily_valued,
        daily_lows,
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

    fn play(key: &str, instrument: &str, trades: Vec<Trade>) -> Play<'static> {
        Play {
            key: key.into(),
            instrument: instrument.into(),
            risk_pct: 0.01,
            max_position_pct: 1.5,
            breaker_exempt: false,
            trades,
            bars: &[],
        }
    }

    /// Daily bars closing at `closes`, the first on Jan `first_day`.
    fn daily_bars(first_day: u32, closes: &[f64]) -> Vec<Candle> {
        closes
            .iter()
            .enumerate()
            .map(|(i, &c)| Candle {
                time: at(first_day, 0) + Duration::days(i as i64),
                mid: crate::engine::types::OHLC {
                    open: c,
                    high: c,
                    low: c,
                    close: c,
                },
                volume: 1,
                bid: None,
                ask: None,
            })
            .collect()
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
    fn two_plays_may_hold_the_same_instrument_as_live() {
        let daily = play("d", "NAS100_USD", vec![trade((5, 10), (7, 20), 0.01)]);
        let intraday = play("m", "NAS100_USD", vec![trade((6, 14), (6, 20), 0.01)]);
        let out = simulate(&[&daily, &intraday], None, at(5, 0), at(8, 0));
        assert_eq!(out.taken, 2);
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
    fn daily_returns_are_valued_each_weekday_with_the_weekend_on_monday() {
        // Mon Jan 5 to Tue Jan 13, a bar a day (weekend included, as FX's
        // Sunday open), held long the whole way: half the account in it.
        let bars = daily_bars(
            5,
            &[100.0, 96.0, 98.0, 100.0, 100.0, 101.0, 102.0, 104.0, 104.0],
        );
        let held = Trade {
            exit_price: 104.0,
            ..trade((5, 0), (13, 0), 0.04)
        };
        let p = Play {
            bars: &bars,
            ..play("a", "SPX500_USD", vec![held])
        };
        let out = simulate(&[&p], None, at(5, 0), at(13, 0));
        let navs = [1.0, 0.98, 0.99, 1.0, 1.0, 1.02, 1.02];
        let want: Vec<f64> = std::iter::once(0.0)
            .chain(navs.windows(2).map(|w| w[1] / w[0] - 1.0))
            .collect();
        assert_eq!(out.daily_valued.len(), want.len());
        for (got, want) in out.daily_valued.iter().zip(&want) {
            assert!((got - want).abs() < 1e-12, "{:?}", out.daily_valued);
        }
        let grown = out.daily_valued.iter().fold(1.0, |nav, r| nav * (1.0 + r)) - 1.0;
        assert!((grown - out.total_return).abs() < 1e-12);
    }

    #[test]
    fn a_dip_inside_a_day_shows_in_the_days_low_not_its_close() {
        // Hourly bars on Tue Jan 6: 100, then 90 at noon, back to 100.
        let bars: Vec<Candle> = [(10, 100.0), (12, 90.0), (14, 100.0), (16, 100.0)]
            .into_iter()
            .map(|(hour, c)| Candle {
                time: at(6, hour),
                mid: crate::engine::types::OHLC {
                    open: c,
                    high: c,
                    low: c,
                    close: c,
                },
                volume: 1,
                bid: None,
                ask: None,
            })
            .collect();
        let p = Play {
            bars: &bars,
            ..play("a", "NAS100_USD", vec![trade((6, 9), (6, 16), 0.0)])
        };
        let out = simulate(&[&p], None, at(6, 0), at(6, 23));
        // Half the account in it: −10% at noon is −5% of the account.
        assert_eq!(out.daily_valued, vec![0.0]);
        assert_eq!(out.daily_lows.len(), 1);
        assert!(
            (out.daily_lows[0] + 0.05).abs() < 1e-12,
            "{:?}",
            out.daily_lows
        );
        assert!((out.max_drawdown - 0.05).abs() < 1e-12);
    }

    #[test]
    fn the_dated_daily_series_shows_dips_on_their_day_and_spans_the_window() {
        // As above, but the window opens the Friday before the trade.
        let bars = daily_bars(
            5,
            &[100.0, 96.0, 98.0, 100.0, 100.0, 101.0, 102.0, 104.0, 104.0],
        );
        let held = Trade {
            exit_price: 104.0,
            ..trade((5, 0), (13, 0), 0.04)
        };
        let p = Play {
            bars: &bars,
            ..play("a", "SPX500_USD", vec![held])
        };
        let out = simulate(&[&p], None, at(2, 0), at(13, 0));
        let day = |d| NaiveDate::from_ymd_opt(2026, 1, d).unwrap();
        let days: Vec<NaiveDate> = out.daily.keys().copied().collect();
        assert_eq!(
            days,
            [2, 5, 6, 7, 8, 9, 12, 13].map(day).to_vec(),
            "every weekday of the window"
        );
        assert_eq!(out.daily[&day(2)], 0.0);
        // Tuesday's 4% dip (half the account) is booked on Tuesday, not
        // folded into the close a week later.
        assert!((out.daily[&day(6)] - (0.98 - 1.0)).abs() < 1e-12);
        let grown = out.daily.values().fold(1.0, |nav, r| nav * (1.0 + r)) - 1.0;
        assert!((grown - out.total_return).abs() < 1e-12);
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

    #[test]
    fn an_open_trade_is_valued_at_every_close() {
        // Long at 100 on Jan 1, down to 90 by Jan 5, back to 100 when it
        // closes Jan 9: no loss at the close, a 10% dip on the way.
        let closes = [100.0, 97.0, 94.0, 92.0, 90.0, 93.0, 96.0, 99.0, 100.0];
        let bars = daily_bars(1, &closes);
        let t = Trade {
            entry_time: at(1, 0),
            exit_time: at(9, 0),
            exit_price: 100.0,
            pnl_percent: 0.0,
            // No stop distance: the position is the cap, the whole account.
            stop_price: 100.0,
            ..trade((1, 0), (9, 0), 0.0)
        };
        let p = Play {
            max_position_pct: 1.0,
            bars: &bars,
            ..play("a", "SPX500_USD", vec![t])
        };
        let out = simulate(&[&p], None, at(1, 0), at(9, 0));
        assert!(out.total_return.abs() < 1e-12);
        assert!((out.max_drawdown - 0.10).abs() < 1e-12);
        assert!((out.summed_max_drawdown - 0.10).abs() < 1e-12);
        let low = out.points.iter().map(|p| p.drawdown).fold(0.0, f64::min);
        assert!((low + 0.10).abs() < 1e-12);

        // Valued only when it closed, it would show no drop at all.
        let blind = Play { bars: &[], ..p };
        assert_eq!(
            simulate(&[&blind], None, at(1, 0), at(9, 0)).max_drawdown,
            0.0
        );
    }

    #[test]
    fn the_financing_a_trade_pays_is_run_up_over_its_life() {
        // Flat price; the trade paid 1% financing over 4 days.
        let bars = daily_bars(1, &[100.0; 5]);
        let t = Trade {
            exit_price: 100.0,
            pnl_percent: -0.01,
            ..trade((1, 0), (5, 0), 0.0)
        };
        assert!((mark_return(&t, &bars[2]) + 0.005).abs() < 1e-12);
        assert_eq!(mark_return(&t, &bars[0]), 0.0);
        assert_eq!(mark_return(&t, &bars[4]), -0.01);
    }

    #[test]
    fn two_markets_are_valued_together_on_one_clock() {
        // A falls 10% while B rises 10%, then each comes back. Each holds
        // half the account (2% stop at 1% risk): together the dips cancel.
        let a_bars = daily_bars(1, &[100.0, 95.0, 90.0, 95.0, 100.0]);
        let b_bars = daily_bars(1, &[100.0, 105.0, 110.0, 105.0, 100.0]);
        let flat = |pnl| Trade {
            exit_price: 100.0,
            ..trade((1, 0), (5, 0), pnl)
        };
        let a = Play {
            bars: &a_bars,
            ..play("a", "SPX500_USD", vec![flat(0.0)])
        };
        let b = Play {
            bars: &b_bars,
            ..play("b", "XAU_USD", vec![flat(0.0)])
        };
        let both = simulate(&[&a, &b], None, at(1, 0), at(5, 0));
        assert!(both.max_drawdown < 1e-12);
        let alone = simulate(&[&a], None, at(1, 0), at(5, 0));
        assert!((alone.max_drawdown - 0.05).abs() < 1e-12);

        // B's bars stop on Jan 3 (a holiday gap): it keeps its last price,
        // +10%, so on Jan 4 the account is A's −2.5% plus B's +5%.
        let b_short = &b_bars[..3];
        let b_gap = Play {
            bars: b_short,
            ..b.clone()
        };
        let out = simulate(&[&a, &b_gap], None, at(1, 0), at(5, 0));
        let jan4 = out.points.iter().find(|p| p.time == at(4, 0)).unwrap();
        assert!((jan4.equity - (0.5 * -0.05 + 0.5 * 0.10)).abs() < 1e-12);
    }

    #[test]
    fn monthly_returns_run_from_the_first_trade_by_calendar_month() {
        // Jan: +2% (half the account × 4%); Feb: nothing; Mar: −1%.
        let t = |m: u32, pnl: f64| Trade {
            entry_time: Utc.with_ymd_and_hms(2026, m, 10, 0, 0, 0).unwrap(),
            exit_time: Utc.with_ymd_and_hms(2026, m, 12, 0, 0, 0).unwrap(),
            ..trade((1, 0), (2, 0), pnl)
        };
        let p = play("a", "SPX500_USD", vec![t(1, 0.04), t(3, -0.02)]);
        let out = simulate(
            &[&p],
            None,
            at(1, 0),
            Utc.with_ymd_and_hms(2026, 3, 31, 0, 0, 0).unwrap(),
        );
        assert_eq!(out.monthly.len(), 3);
        assert!((out.monthly[0] - 0.02).abs() < 1e-12);
        assert_eq!(out.monthly[1], 0.0);
        assert!((out.monthly[2] + 0.01).abs() < 1e-12);
    }
}
