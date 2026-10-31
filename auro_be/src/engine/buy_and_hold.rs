//! Just holding: what owning the same funds over the same bars would have
//! done, for a long-only result to be read against. A long-only rule on
//! assets that tend to rise can pass "better than zero" by riding the rise;
//! beside holding, it shows whether the rule added anything.
//!
//! Equal weights, rebalanced every day (each fund's daily return averaged
//! over the funds trading that day), dividends paid on their ex-dates, no
//! costs: the plain benchmark, fully invested. Its Sharpe compares directly
//! with a strategy's; its return and worst drop are for a fully invested
//! account, so a strategy holding less should be read on Sharpe and on
//! return per unit of worst drop.

use std::collections::BTreeMap;

use chrono::NaiveDate;
use chrono_tz::America::New_York;
use serde::Serialize;

use crate::engine::stats::annual_sharpe_of;
use crate::engine::types::Candle;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Hold {
    /// Growth over the whole stretch (0.5 = +50%).
    pub total_return: f64,
    /// Compounded a year.
    pub annual_return: f64,
    /// Worst fall from a high, valued at each day's close (≥ 0).
    pub max_drawdown: f64,
    /// From the daily returns, √252 a year (as the strategy's).
    pub annual_sharpe: f64,
    /// The daily returns' spread, √252 a year: how much it swings.
    pub annual_vol: f64,
    pub first_day: NaiveDate,
    pub last_day: NaiveDate,
    /// Each day's return, in order: holding redrawn the way a strategy is
    /// in Monte Carlo.
    #[serde(skip)]
    pub daily: Vec<f64>,
}

/// One fund: its bars and its dividends, `(ex-date, cash a share)`.
pub type Fund<'a> = (&'a [Candle], &'a [(NaiveDate, f64)]);

/// Holding `funds` in equal weights; None with under two trading days.
pub fn hold(funds: &[Fund]) -> Option<Hold> {
    // Each fund's return each day it has a close and a close before it.
    let mut by_day: BTreeMap<NaiveDate, (f64, usize)> = BTreeMap::new();
    for (candles, dividends) in funds {
        let closes = day_closes(candles);
        for (prev, today) in closes.iter().zip(closes.iter().skip(1)) {
            let (prev_day, prev_close) = *prev;
            let (day, close) = *today;
            if prev_close <= 0.0 {
                continue;
            }
            let paid: f64 = dividends
                .iter()
                .filter(|(ex, _)| *ex > prev_day && *ex <= day)
                .map(|(_, cash)| cash)
                .sum();
            let r = (close + paid) / prev_close - 1.0;
            let slot = by_day.entry(day).or_insert((0.0, 0));
            slot.0 += r;
            slot.1 += 1;
        }
    }
    if by_day.len() < 2 {
        return None;
    }
    let daily: BTreeMap<NaiveDate, f64> = by_day
        .into_iter()
        .map(|(day, (sum, n))| (day, sum / n as f64))
        .collect();

    let (mut nav, mut peak, mut worst) = (1.0_f64, 1.0_f64, 0.0_f64);
    for r in daily.values() {
        nav *= 1.0 + r;
        peak = peak.max(nav);
        worst = worst.min(nav / peak - 1.0);
    }
    let n = daily.len() as f64;
    let mean = daily.values().sum::<f64>() / n;
    let sd = (daily.values().map(|r| (r - mean).powi(2)).sum::<f64>() / n).sqrt();
    let first_day = *daily.keys().next()?;
    let last_day = *daily.keys().next_back()?;
    let years = (last_day - first_day).num_days().max(1) as f64 / 365.25;
    Some(Hold {
        total_return: nav - 1.0,
        annual_return: if nav > 0.0 {
            nav.powf(1.0 / years) - 1.0
        } else {
            -1.0
        },
        max_drawdown: worst.abs(),
        annual_sharpe: annual_sharpe_of(&daily),
        annual_vol: sd * 252f64.sqrt(),
        first_day,
        last_day,
        daily: daily.into_values().collect(),
    })
}

/// Each New York trading day's last close, in order.
fn day_closes(candles: &[Candle]) -> Vec<(NaiveDate, f64)> {
    let mut out: Vec<(NaiveDate, f64)> = Vec::new();
    for c in candles {
        let day = c.time.with_timezone(&New_York).date_naive();
        match out.last_mut() {
            Some((last, close)) if *last == day => *close = c.mid.close,
            _ => out.push((day, c.mid.close)),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::{TimeZone, Utc};

    fn bars(closes: &[f64]) -> Vec<Candle> {
        closes
            .iter()
            .enumerate()
            .map(|(i, &c)| {
                // Weekdays from Mon Jan 5 2026, 04:00 UTC (midnight New York).
                let day = [5, 6, 7, 8, 9, 12, 13, 14][i];
                Candle::from_trade_bar(
                    Utc.with_ymd_and_hms(2026, 1, day, 5, 0, 0).unwrap(),
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

    #[test]
    fn one_fund_grows_with_its_price_and_its_dividends() {
        let spy = bars(&[100.0, 110.0, 99.0, 110.0]);
        let paid = [(NaiveDate::from_ymd_opt(2026, 1, 8).unwrap(), 1.0)];
        let h = hold(&[(&spy, &paid)]).unwrap();
        // 100 → 110 → 99 → 110 plus the dollar paid on the 8th.
        let want = 1.1 * 0.9 * (111.0 / 99.0) - 1.0;
        assert!((h.total_return - want).abs() < 1e-12);
        assert!((h.max_drawdown - 0.1).abs() < 1e-12);
    }

    #[test]
    fn funds_are_held_in_equal_weights() {
        let up = bars(&[100.0, 110.0, 110.0]);
        let flat = bars(&[50.0, 50.0, 50.0]);
        let h = hold(&[(&up, &[]), (&flat, &[])]).unwrap();
        assert!((h.total_return - 0.05).abs() < 1e-12);
    }

    #[test]
    fn too_little_history_has_no_benchmark() {
        assert_eq!(hold(&[(&bars(&[100.0, 101.0]), &[])]), None);
    }
}
