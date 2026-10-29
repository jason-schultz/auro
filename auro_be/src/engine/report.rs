//! What a backtest looked like over time, and how sturdy it is.
//!
//! - `equity`: the strategy's running return against just holding the
//!   instrument over the same bars, and its drawdown, sampled for a chart.
//!   Both are "as if the whole account were in the trade": the strategy adds
//!   up each trade's return (the pipeline's `total_return`), holding is the
//!   price change since the first bar.
//! - `with_param`: the strategy JSON with one block setting changed, for
//!   re-running it at nearby settings (the "is it fragile?" grid).

use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::Value;

use crate::engine::types::{Candle, Trade};

/// Points a chart gets at most; the curves are sampled down to this.
const MAX_POINTS: usize = 240;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct EquityPoint {
    pub time: DateTime<Utc>,
    /// Running sum of closed trades' returns (0.05 = +5%).
    pub strategy: f64,
    /// Price change since the first bar.
    pub hold: f64,
    /// How far the strategy's running return is below its best so far (≤ 0).
    pub drawdown: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct EquitySummary {
    pub strategy_return: f64,
    pub hold_return: f64,
    pub strategy_max_drawdown: f64,
    pub hold_max_drawdown: f64,
    /// Share of the window a trade was open (0–1).
    pub time_in_market: f64,
    pub num_trades: usize,
    pub from: DateTime<Utc>,
    pub to: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct EquityReport {
    pub points: Vec<EquityPoint>,
    pub summary: EquitySummary,
}

/// The strategy's trades against holding over `candles`. None without candles.
pub fn equity(candles: &[Candle], trades: &[Trade]) -> Option<EquityReport> {
    let first = candles.first()?;
    let last = candles.last()?;
    let base = first.mid.close;
    if base <= 0.0 {
        return None;
    }

    let mut closed: Vec<&Trade> = trades.iter().collect();
    closed.sort_by_key(|t| t.exit_time);

    // Strategy return and hold return at every bar, then the drawdowns.
    let mut next = 0;
    let mut running = 0.0;
    let mut best = 0.0_f64;
    let mut hold_best = 0.0_f64;
    let mut strategy_max_dd = 0.0_f64;
    let mut hold_max_dd = 0.0_f64;
    let mut all: Vec<EquityPoint> = Vec::with_capacity(candles.len());

    for candle in candles {
        while next < closed.len() && closed[next].exit_time <= candle.time {
            running += closed[next].pnl_percent;
            next += 1;
        }
        best = best.max(running);
        // Relative to the best, as the backtest's drawdown (`stats.rs`) and
        // holding's below are: from +100% to +50% is a 25% drop.
        let drawdown = (1.0 + running) / (1.0 + best) - 1.0;
        strategy_max_dd = strategy_max_dd.min(drawdown);

        let hold = candle.mid.close / base - 1.0;
        hold_best = hold_best.max(hold);
        hold_max_dd = hold_max_dd.min((1.0 + hold) / (1.0 + hold_best) - 1.0);

        all.push(EquityPoint {
            time: candle.time,
            strategy: running,
            hold,
            drawdown,
        });
    }

    let window = (last.time - first.time).num_seconds().max(1) as f64;
    let in_market: f64 = trades
        .iter()
        .map(|t| (t.exit_time - t.entry_time).num_seconds().max(0) as f64)
        .sum();

    Some(EquityReport {
        summary: EquitySummary {
            strategy_return: trades.iter().map(|t| t.pnl_percent).sum(),
            hold_return: last.mid.close / base - 1.0,
            strategy_max_drawdown: strategy_max_dd.abs(),
            hold_max_drawdown: hold_max_dd.abs(),
            time_in_market: (in_market / window).min(1.0),
            num_trades: trades.len(),
            from: first.time,
            to: last.time,
        },
        points: sample(all),
    })
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
    use crate::engine::test_candles::daily;
    use crate::engine::types::{Direction, EntryReason, ExitReason};
    use serde_json::json;

    fn trade(candles: &[Candle], from: usize, to: usize, pnl: f64) -> Trade {
        Trade {
            direction: Direction::Long,
            entry_price: candles[from].mid.close,
            exit_price: candles[to].mid.close,
            entry_time: candles[from].time,
            exit_time: candles[to].time,
            pnl_percent: pnl,
            entry_reason: EntryReason::Indicator {
                name: "test",
                value: 0.0,
            },
            exit_reason: ExitReason::TrendReversal,
            stop_price: 0.0,
        }
    }

    #[test]
    fn the_strategy_and_holding_are_measured_over_the_same_bars() {
        let candles = daily(&[100.0, 110.0, 90.0, 120.0, 120.0]);
        let trades = vec![trade(&candles, 0, 1, 0.10), trade(&candles, 2, 3, -0.05)];
        let report = equity(&candles, &trades).unwrap();

        assert_eq!(
            report.points.iter().map(|p| p.strategy).collect::<Vec<_>>(),
            vec![0.0, 0.10, 0.10, 0.05, 0.05]
        );
        assert!((report.summary.hold_return - 0.20).abs() < 1e-12);
        // From +10% to +5%: 1.05 / 1.10 − 1, a 4.5% drop, measured like holding's.
        assert!((report.summary.strategy_max_drawdown - (1.0 - 1.05 / 1.10)).abs() < 1e-12);
        // Holding fell from 110 to 90 at its worst: −18.2%.
        assert!((report.summary.hold_max_drawdown - 20.0 / 110.0).abs() < 1e-12);
        // Two one-day trades in a four-day window.
        assert!((report.summary.time_in_market - 0.5).abs() < 1e-12);
    }

    #[test]
    fn long_histories_are_sampled_down_keeping_the_last_point() {
        let candles = daily(&vec![100.0; 1000]);
        let report = equity(&candles, &[]).unwrap();
        assert!(report.points.len() <= MAX_POINTS + 1);
        assert_eq!(report.points.last().unwrap().time, candles[999].time);
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
