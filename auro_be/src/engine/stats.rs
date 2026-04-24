use crate::engine::types::Trade;

#[derive(Debug)]
pub struct BacktestStats {
    pub total_return: f64,
    pub win_rate: f64,
    pub avg_win: f64,
    pub avg_loss: f64,
    pub max_drawdown: f64,
    pub sharpe_ratio: f64,
    pub num_trades: usize,
}

/// Calculates the backtest statistics for a given set of trades.
///
/// # Arguments
///
/// * `trades` - A slice of `Trade` structs representing the trades to analyze.
///
/// # Returns
///
/// A `BacktestStats` struct containing the calculated statistics.
pub fn calculate_backtest_stats(trades: &[Trade]) -> BacktestStats {
    if trades.is_empty() {
        return BacktestStats {
            total_return: 0.0,
            win_rate: 0.0,
            avg_win: 0.0,
            avg_loss: 0.0,
            max_drawdown: 0.0,
            sharpe_ratio: 0.0,
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
        num_trades,
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
            entry_reason: EntryReason::BelowMA {
                ma_value: 0.0,
                deviation_pct: 0.0,
            },
            exit_reason: ExitReason::TakeProfit,
        }
    }

    #[test]
    fn test_calculate_backtest_stats_empty() {
        let trades = vec![];
        let stats = calculate_backtest_stats(&trades);
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
        let stats = calculate_backtest_stats(&trades);
        assert_eq!(stats.total_return, 25.0);
        assert_eq!(stats.win_rate, 2.0 / 3.0);
        assert_eq!(stats.avg_win, 15.0);
        assert_eq!(stats.avg_loss, -5.0);
        assert!(stats.max_drawdown < 0.0);
        assert!(stats.sharpe_ratio > 0.0);
        assert_eq!(stats.num_trades, 3);
    }
}
