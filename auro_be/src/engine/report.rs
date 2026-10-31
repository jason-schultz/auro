//! What a backtest looked like over time, and how sturdy it is.
//!
//! - `equity`: the strategy's account against just holding the market over
//!   the same days, measured the same way: the account as live sizes its
//!   trades (`AccountSizing`), open trades valued every day, compounded,
//!   beside holding compounded from the daily closes (with dividends for
//!   shares held outright). A strategy in the market a few hours a week
//!   swings far less than holding, so holding is also shown at the
//!   strategy's risk (scaled to swing as much), each calendar year side by
//!   side, and how much the two move together.
//! - `with_param`: the strategy JSON with one block setting changed, for
//!   re-running it at nearby settings (the "is it fragile?" grid).

use std::collections::BTreeMap;

use chrono::{DateTime, Datelike, NaiveDate, Utc};
use serde::Serialize;
use serde_json::Value;

use crate::engine::portfolio::correlation;
use crate::engine::stats::{annual_sharpe_of, backtest_on_account, AccountSizing};
use crate::engine::types::{Candle, Trade};

/// Points a chart gets at most; the curves are sampled down to this.
const MAX_POINTS: usize = 240;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct EquityPoint {
    pub time: DateTime<Utc>,
    /// The account's return so far (0.05 = +5%).
    pub strategy: f64,
    /// Holding's return so far.
    pub hold: f64,
    /// Holding at the strategy's risk: its daily moves scaled to swing as
    /// much as the strategy's account.
    pub matched: f64,
    /// How far the account is below its best so far (≤ 0).
    pub drawdown: f64,
}

/// One calendar year of each, compounded (0.1 = +10%).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct YearRow {
    pub year: i32,
    pub strategy: f64,
    pub hold: f64,
    pub matched: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct EquitySummary {
    /// The account at the strategy's sizing, compounded.
    pub strategy_return: f64,
    /// The account's worst fall from a high (≥ 0), valued at every bar.
    pub strategy_max_drawdown: f64,
    pub strategy_annual_sharpe: f64,
    pub hold_return: f64,
    /// Holding's worst fall from a high (≥ 0), valued at each day's close.
    pub hold_max_drawdown: f64,
    pub hold_annual_sharpe: f64,
    /// Holding scaled to the strategy's risk (`risk_scale` of the money in
    /// the market), compounded.
    pub matched_return: f64,
    pub matched_max_drawdown: f64,
    /// The strategy's daily swings over holding's: the share of the money
    /// holding would keep in the market to swing as much.
    pub risk_scale: f64,
    /// How the two move together day to day (−1 to 1; near 0: unrelated).
    pub correlation: Option<f64>,
    /// Share of the window a trade was open (0–1).
    pub time_in_market: f64,
    pub num_trades: usize,
    /// The risk per trade the account assumes.
    pub risk_pct: f64,
    pub from: DateTime<Utc>,
    pub to: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct EquityReport {
    pub points: Vec<EquityPoint>,
    pub summary: EquitySummary,
    pub years: Vec<YearRow>,
}

/// The strategy's `trades` on an account sized by `sizing`, against holding
/// over `candles` (paying `dividends`, `(ex-date, cash a share)`, for
/// shares held outright; none for a CFD). None without candles.
pub fn equity(
    candles: &[Candle],
    trades: &[Trade],
    sizing: AccountSizing,
    dividends: &[(NaiveDate, f64)],
) -> Option<EquityReport> {
    let first = candles.first()?;
    let last = candles.last()?;
    let (stats, outcome) = backtest_on_account(trades, candles, sizing);

    // Both on the account's clock: its weekdays (UTC), weekends on Monday.
    let strategy = outcome.daily;
    let hold = on_days(&strategy, &day_closes(candles), dividends);
    let risk_scale = match (vol(&strategy), vol(&hold)) {
        (s, h) if h > 0.0 => s / h,
        _ => 0.0,
    };
    let matched: BTreeMap<NaiveDate, f64> =
        hold.iter().map(|(d, r)| (*d, r * risk_scale)).collect();

    let (s_curve, h_curve, m_curve) = (curve(&strategy), curve(&hold), curve(&matched));
    let points = strategy
        .keys()
        .enumerate()
        .map(|(i, day)| EquityPoint {
            time: day.and_hms_opt(0, 0, 0).unwrap_or_default().and_utc(),
            strategy: s_curve[i].0,
            hold: h_curve[i].0,
            matched: m_curve[i].0,
            drawdown: s_curve[i].1,
        })
        .collect();

    let window = (last.time - first.time).num_seconds().max(1) as f64;
    let in_market: f64 = trades
        .iter()
        .map(|t| (t.exit_time - t.entry_time).num_seconds().max(0) as f64)
        .sum();
    let worst = |c: &[(f64, f64)]| c.iter().map(|p| -p.1).fold(0.0, f64::max);
    let end = |c: &[(f64, f64)]| c.last().map_or(0.0, |p| p.0);

    Some(EquityReport {
        summary: EquitySummary {
            strategy_return: outcome.total_return,
            strategy_max_drawdown: outcome.max_drawdown,
            strategy_annual_sharpe: stats.annual_sharpe,
            hold_return: end(&h_curve),
            hold_max_drawdown: worst(&h_curve),
            hold_annual_sharpe: annual_sharpe_of(&hold),
            matched_return: end(&m_curve),
            matched_max_drawdown: worst(&m_curve),
            risk_scale,
            correlation: correlation(&strategy, &hold),
            time_in_market: (in_market / window).min(1.0),
            num_trades: trades.len(),
            risk_pct: sizing.risk_pct,
            from: first.time,
            to: last.time,
        },
        years: years(&strategy, &hold, &matched),
        points: sample(points),
    })
}

/// Each UTC day's last close, as the account is valued at each day's last
/// bar.
fn day_closes(candles: &[Candle]) -> BTreeMap<NaiveDate, f64> {
    candles
        .iter()
        .map(|c| (c.time.date_naive(), c.mid.close))
        .collect()
}

/// Holding's return on each of `clock`'s days: the latest close by that
/// day over the latest close by the day before it on the clock, plus any
/// dividend going ex in between. The first day is 0, as the account's is.
fn on_days(
    clock: &BTreeMap<NaiveDate, f64>,
    closes: &BTreeMap<NaiveDate, f64>,
    dividends: &[(NaiveDate, f64)],
) -> BTreeMap<NaiveDate, f64> {
    let close_by = |day: NaiveDate| closes.range(..=day).next_back().map(|(_, c)| *c);
    let mut prev: Option<(NaiveDate, f64)> = None;
    clock
        .keys()
        .map(|&day| {
            let close = close_by(day);
            let r = match (prev, close) {
                (Some((prev_day, p)), Some(c)) if p > 0.0 => {
                    let paid: f64 = dividends
                        .iter()
                        .filter(|(ex, _)| *ex > prev_day && *ex <= day)
                        .map(|(_, cash)| cash)
                        .sum();
                    (c + paid) / p - 1.0
                }
                _ => 0.0,
            };
            if let Some(c) = close {
                prev = Some((day, c));
            }
            (day, r)
        })
        .collect()
}

/// The daily returns' spread (population), a year's worth.
fn vol(daily: &BTreeMap<NaiveDate, f64>) -> f64 {
    let n = daily.len() as f64;
    if n < 2.0 {
        return 0.0;
    }
    let mean = daily.values().sum::<f64>() / n;
    (daily.values().map(|r| (r - mean).powi(2)).sum::<f64>() / n).sqrt() * 252f64.sqrt()
}

/// Compounded return so far and the fall from the best so far (≤ 0), each
/// day.
fn curve(daily: &BTreeMap<NaiveDate, f64>) -> Vec<(f64, f64)> {
    let (mut nav, mut peak) = (1.0_f64, 1.0_f64);
    daily
        .values()
        .map(|r| {
            nav *= 1.0 + r;
            peak = peak.max(nav);
            (nav - 1.0, nav / peak - 1.0)
        })
        .collect()
}

/// Each calendar year of the three, compounded, oldest first.
fn years(
    strategy: &BTreeMap<NaiveDate, f64>,
    hold: &BTreeMap<NaiveDate, f64>,
    matched: &BTreeMap<NaiveDate, f64>,
) -> Vec<YearRow> {
    let by_year = |daily: &BTreeMap<NaiveDate, f64>| {
        let mut out: BTreeMap<i32, f64> = BTreeMap::new();
        for (day, r) in daily {
            *out.entry(day.year()).or_insert(1.0) *= 1.0 + r;
        }
        out
    };
    let (s, h, m) = (by_year(strategy), by_year(hold), by_year(matched));
    s.iter()
        .map(|(year, g)| YearRow {
            year: *year,
            strategy: g - 1.0,
            hold: h.get(year).map_or(0.0, |g| g - 1.0),
            matched: m.get(year).map_or(0.0, |g| g - 1.0),
        })
        .collect()
}

/// Every `n`th point, always keeping the last, so a chart stays light.
fn sample(points: Vec<EquityPoint>) -> Vec<EquityPoint> {
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

/// The strategy JSON with `components.<component>.params.<param>` set to
/// `value`, written as a whole number when it is one (bar counts must be;
/// the caller rounds them). None when the strategy has no such setting.
pub fn with_param(parameters: &Value, component: &str, param: &str, value: f64) -> Option<Value> {
    let mut changed = parameters.clone();
    let slot = changed
        .get_mut("components")?
        .get_mut(component)?
        .get_mut("params")?
        .get_mut(param)?;
    *slot = if value.fract() == 0.0 {
        Value::from(value as i64)
    } else {
        Value::from(value)
    };
    Some(changed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::{Direction, EntryReason, ExitReason, OHLC};
    use chrono::{Duration, TimeZone};
    use serde_json::json;

    /// One bar a weekday from Mon Jan 5 2026, 20:00 UTC.
    fn weekdays(closes: &[f64]) -> Vec<Candle> {
        let start = Utc.with_ymd_and_hms(2026, 1, 5, 20, 0, 0).unwrap();
        closes
            .iter()
            .enumerate()
            .map(|(i, &c)| {
                let week = i as i64 / 5;
                let day = start + Duration::days(week * 7 + i as i64 % 5);
                Candle::from_trade_bar(
                    day,
                    OHLC {
                        open: c,
                        high: c,
                        low: c,
                        close: c,
                    },
                    0.0,
                )
            })
            .collect()
    }

    fn trade(candles: &[Candle], from: usize, to: usize) -> Trade {
        let (entry, exit) = (candles[from].mid.close, candles[to].mid.close);
        Trade {
            direction: Direction::Long,
            entry_price: entry,
            exit_price: exit,
            entry_time: candles[from].time,
            exit_time: candles[to].time,
            pnl_percent: exit / entry - 1.0,
            entry_reason: EntryReason::Indicator {
                name: "test",
                value: 0.0,
            },
            exit_reason: ExitReason::TrendReversal,
            // A 10% stop: at 1% risk the position is 10% of the account.
            stop_price: entry * 0.9,
        }
    }

    const SIZING: AccountSizing = AccountSizing {
        risk_pct: 0.01,
        max_position_pct: 1.0,
    };

    #[test]
    fn the_account_and_holding_are_measured_the_same_way() {
        let candles = weekdays(&[100.0, 110.0, 90.0, 120.0, 120.0]);
        let trades = vec![trade(&candles, 0, 1)];
        let report = equity(&candles, &trades, SIZING, &[]).unwrap();
        let s = &report.summary;

        // A tenth of the account caught the 10% rise.
        assert!((s.strategy_return - 0.01).abs() < 1e-12);
        assert!((s.hold_return - 0.20).abs() < 1e-12);
        // Holding fell from 110 to 90 at its worst.
        assert!((s.hold_max_drawdown - 20.0 / 110.0).abs() < 1e-12);
        // The strategy swings far less than holding, so holding at its risk
        // keeps only part of the money in the market.
        assert!(s.risk_scale > 0.0 && s.risk_scale < 1.0);
        assert!(s.matched_return > 0.0 && s.matched_return < s.hold_return);
        assert_eq!(report.years.len(), 1);
        assert!((report.years[0].hold - 0.20).abs() < 1e-12);
    }

    #[test]
    fn holding_at_the_strategys_risk_swings_as_much() {
        let closes: Vec<f64> = (0..60)
            .map(|i| 100.0 + 8.0 * (i as f64 * 0.9).sin() + i as f64 * 0.2)
            .collect();
        let candles = weekdays(&closes);
        let trades: Vec<Trade> = (0..55)
            .step_by(6)
            .map(|i| trade(&candles, i, i + 2))
            .collect();
        let report = equity(&candles, &trades, SIZING, &[]).unwrap();
        let (_, outcome) = backtest_on_account(&trades, &candles, SIZING);
        let hold = on_days(&outcome.daily, &day_closes(&candles), &[]);
        let matched: BTreeMap<NaiveDate, f64> = hold
            .iter()
            .map(|(d, r)| (*d, r * report.summary.risk_scale))
            .collect();
        assert!((vol(&matched) - vol(&outcome.daily)).abs() < 1e-12);
    }

    #[test]
    fn dividends_count_in_holding() {
        let candles = weekdays(&[100.0, 100.0, 100.0]);
        let ex = candles[1].time.date_naive();
        let report = equity(&candles, &[], SIZING, &[(ex, 2.0)]).unwrap();
        assert!((report.summary.hold_return - 0.02).abs() < 1e-12);
    }

    #[test]
    fn long_histories_are_sampled_down_keeping_the_last_point() {
        let candles = weekdays(&vec![100.0; 1000]);
        let report = equity(&candles, &[], SIZING, &[]).unwrap();
        assert!(report.points.len() <= MAX_POINTS + 1);
        assert_eq!(
            report.points.last().unwrap().time.date_naive(),
            candles[999].time.date_naive()
        );
    }

    #[test]
    fn a_setting_is_changed_and_whole_numbers_stay_whole() {
        let params = json!({"components": {"r": {"type": "RsiReversion",
            "params": {"rsi_period": 2, "oversold": 20.0}}}});

        let changed = with_param(&params, "r", "rsi_period", 3.0).unwrap();
        assert_eq!(changed["components"]["r"]["params"]["rsi_period"], json!(3));

        let changed = with_param(&params, "r", "oversold", 17.5).unwrap();
        assert_eq!(
            changed["components"]["r"]["params"]["oversold"],
            json!(17.5)
        );

        assert!(with_param(&params, "r", "missing", 1.0).is_none());
    }
}
