use std::collections::BTreeMap;

use chrono::{DateTime, Datelike, Duration, NaiveDate, Utc, Weekday};

use crate::engine::types::Trade;

/// Trading days a year, for annualizing a daily Sharpe.
const TRADING_DAYS: f64 = 252.0;

#[derive(Debug, Clone, serde::Serialize)]
pub struct BacktestStats {
    pub total_return: f64,
    pub win_rate: f64,
    pub avg_win: f64,
    pub avg_loss: f64,
    pub max_drawdown: f64,
    /// Per trade: the average trade over how much trades vary. Only
    /// meaningful with the trade count (`pipeline::t_stat`).
    pub sharpe_ratio: f64,
    /// The standard Sharpe, a year's worth (`annual_sharpe`): comparable
    /// across strategies and with what charting tools report.
    pub annual_sharpe: f64,
    pub num_trades: usize,
}

/// Calculates the backtest statistics for a given set of trades.
///
/// # Arguments
///
/// * `trades` - A slice of `Trade` structs representing the trades to analyze.
/// * `from`, `to` - The stretch they were traded over (the candles' first and
///   last bar), for the annual Sharpe.
///
/// # Returns
///
/// A `BacktestStats` struct containing the calculated statistics.
pub fn calculate_backtest_stats(
    trades: &[Trade],
    from: DateTime<Utc>,
    to: DateTime<Utc>,
) -> BacktestStats {
    if trades.is_empty() {
        return BacktestStats {
            total_return: 0.0,
            win_rate: 0.0,
            avg_win: 0.0,
            avg_loss: 0.0,
            max_drawdown: 0.0,
            sharpe_ratio: 0.0,
            annual_sharpe: 0.0,
            num_trades: 0,
        };
    }

    let winners = trades
        .iter()
        .filter(|t| t.pnl_percent > 0.0)
        .map(|t| t.pnl_percent)
        .collect::<Vec<_>>();
    let losers = trades
        .iter()
        .filter(|t| t.pnl_percent < 0.0)
        .map(|t| t.pnl_percent)
        .collect::<Vec<_>>();

    let total_return = trades.iter().map(|t| t.pnl_percent).sum::<f64>();
    let win_rate =
        trades.iter().filter(|t| t.pnl_percent > 0.0).count() as f64 / trades.len() as f64;
    let avg_win = if winners.is_empty() {
        0.0
    } else {
        winners.iter().sum::<f64>() / winners.len() as f64
    };
    let avg_loss = if losers.is_empty() {
        0.0
    } else {
        losers.iter().sum::<f64>() / losers.len() as f64
    };

    let pnls: Vec<f64> = trades.iter().map(|t| t.pnl_percent).collect();
    let mean = pnls.iter().sum::<f64>() / pnls.len() as f64;
    let variance = pnls.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / pnls.len() as f64;
    let std_dev = variance.sqrt();
    let sharpe_ratio = if std_dev == 0.0 { 0.0 } else { mean / std_dev };

    let mut cumulative = 0.0;
    let mut peak = 0.0;
    let mut max_drawdown = 0.0;

    for trade in trades {
        cumulative += trade.pnl_percent;
        if cumulative > peak {
            peak = cumulative;
        }
        let drawdown = (cumulative - peak) / (1.0 + peak);
        if drawdown < max_drawdown {
            max_drawdown = drawdown;
        }
    }
    let num_trades = trades.len();

    BacktestStats {
        total_return,
        win_rate,
        avg_win,
        avg_loss,
        max_drawdown,
        sharpe_ratio,
        annual_sharpe: annual_sharpe(trades, from, to),
        num_trades,
    }
}

/// The standard (annualized) Sharpe from daily returns: each trade's return
/// is booked on the UTC day it closes, every weekday from `from` to `to`
/// without one counts as a flat day, and the daily mean over the daily
/// standard deviation (population, like the per-trade figure) is scaled by
/// √252. Days out of the market count, so a strategy that trades rarely
/// isn't flattered. 0 with under two days or no variation.
pub fn annual_sharpe(trades: &[Trade], from: DateTime<Utc>, to: DateTime<Utc>) -> f64 {
    let mut days: BTreeMap<NaiveDate, f64> = BTreeMap::new();
    let (first, last) = (from.date_naive(), to.date_naive());
    let mut day = first;
    while day <= last {
        if !matches!(day.weekday(), Weekday::Sat | Weekday::Sun) {
            days.insert(day, 0.0);
        }
        day += Duration::days(1);
    }
    for trade in trades {
        *days.entry(trade.exit_time.date_naive()).or_insert(0.0) += trade.pnl_percent;
    }

    let n = days.len() as f64;
    if n < 2.0 {
        return 0.0;
    }
    let mean = days.values().sum::<f64>() / n;
    let std_dev = (days.values().map(|r| (r - mean).powi(2)).sum::<f64>() / n).sqrt();
    if std_dev == 0.0 {
        0.0
    } else {
        mean / std_dev * TRADING_DAYS.sqrt()
    }
}

#[cfg(test)]
mod tests {
    use chrono::Utc;

    use crate::engine::types::{Direction, EntryReason, ExitReason, Trade};

    use super::*;

    fn dummy_trade(pnl: f64) -> Trade {
        Trade {
            direction: Direction::Long,
            pnl_percent: pnl,
            entry_price: 1.0,
            exit_price: 1.0,
            entry_time: Utc::now(),
            exit_time: Utc::now(),
            entry_reason: EntryReason::CrossAbove {
                fast_ma: 0.0,
                slow_ma: 0.0,
            },
            exit_reason: ExitReason::TrendReversal,
        }
    }

    #[test]
    fn test_calculate_backtest_stats_empty() {
        let trades = vec![];
        let stats = calculate_backtest_stats(&trades, Utc::now(), Utc::now());
        assert_eq!(stats.total_return, 0.0);
        assert_eq!(stats.win_rate, 0.0);
        assert_eq!(stats.avg_win, 0.0);
        assert_eq!(stats.avg_loss, 0.0);
        assert_eq!(stats.max_drawdown, 0.0);
        assert_eq!(stats.sharpe_ratio, 0.0);
        assert_eq!(stats.num_trades, 0);
    }

    #[test]
    fn test_calculate_backtest_stats() {
        let trades = vec![dummy_trade(10.0), dummy_trade(-5.0), dummy_trade(20.0)];
        let stats = calculate_backtest_stats(&trades, Utc::now(), Utc::now());
        assert_eq!(stats.total_return, 25.0);
        assert_eq!(stats.win_rate, 2.0 / 3.0);
        assert_eq!(stats.avg_win, 15.0);
        assert_eq!(stats.avg_loss, -5.0);
        assert!(stats.max_drawdown < 0.0);
        assert!(stats.sharpe_ratio > 0.0);
        assert_eq!(stats.num_trades, 3);
    }

    fn closed_on(day: &str, pnl: f64) -> Trade {
        let at = chrono::DateTime::parse_from_rfc3339(&format!("{day}T20:00:00Z"))
            .unwrap()
            .with_timezone(&Utc);
        Trade {
            exit_time: at,
            entry_time: at,
            ..dummy_trade(pnl)
        }
    }

    fn utc(day: &str) -> chrono::DateTime<Utc> {
        chrono::DateTime::parse_from_rfc3339(&format!("{day}T00:00:00Z"))
            .unwrap()
            .with_timezone(&Utc)
    }

    #[test]
    fn annual_sharpe_counts_flat_weekdays_and_skips_weekends() {
        // Mon 2026-01-05 to Fri 2026-01-16: ten weekdays, two trades.
        let trades = vec![
            closed_on("2026-01-06", 0.02),
            closed_on("2026-01-13", -0.01),
        ];
        let got = annual_sharpe(&trades, utc("2026-01-05"), utc("2026-01-16"));

        let days = [0.0, 0.02, 0.0, 0.0, 0.0, 0.0, -0.01, 0.0, 0.0, 0.0];
        let mean = days.iter().sum::<f64>() / 10.0;
        let sd = (days.iter().map(|d| (d - mean).powi(2)).sum::<f64>() / 10.0).sqrt();
        assert!((got - mean / sd * 252f64.sqrt()).abs() < 1e-12);
    }

    #[test]
    fn annual_sharpe_is_zero_without_variation_or_days() {
        assert_eq!(
            annual_sharpe(&[], utc("2026-01-05"), utc("2026-01-16")),
            0.0
        );
        assert_eq!(
            annual_sharpe(&[], utc("2026-01-05"), utc("2026-01-05")),
            0.0
        );
    }

    #[test]
    fn a_steady_small_edge_reads_as_a_normal_annual_sharpe() {
        // Twenty trades a year at +0.5% / -0.4% alternating: a modest edge.
        // Per trade that is about 0.1; a year of it is roughly 0.5, not 0.1.
        let mut trades = Vec::new();
        let mut day = utc("2025-01-06");
        for i in 0..20 {
            day += chrono::Duration::days(14);
            let pnl = if i % 2 == 0 { 0.005 } else { -0.004 };
            trades.push(Trade {
                exit_time: day,
                entry_time: day,
                ..dummy_trade(pnl)
            });
        }
        let stats = calculate_backtest_stats(&trades, utc("2025-01-06"), day);
        assert!(stats.sharpe_ratio < 0.15);
        assert!(stats.annual_sharpe > 0.3 && stats.annual_sharpe < 0.6);
    }
}
