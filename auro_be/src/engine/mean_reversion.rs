use chrono::{DateTime, Utc};

use crate::{
    engine::types::{Direction, EntryReason, ExitReason, Trade},
    oanda::models::CandleRecord,
};

pub enum MRSignal {
    Enter { ma_value: f64, deviation_pct: f64 },
    Exit { pnl: f64 },
    None,
}

#[derive(Debug)]
pub struct MeanReversionParams {
    pub ma_period: usize,     // eg: 20 Candles
    pub entry_threshold: f64, // eg: -0.005 (price is 0.5% below the MA)
    pub exit_threshold: f64,  // eg: 0.003 (price recovered 0.3% from entry)
    pub stop_loss: f64,       // eg: -0.001 (price dropped 1% from entry)
}

/// Runs the mean reversion strategy on the given candles and returns a vector of trades.
///
/// # Arguments
///
/// * `candles` - A slice of `CandleRecord` structs representing the price data.
/// * `params` - A `MeanReversionParams` struct containing the strategy parameters.
///
/// # Returns
///
/// A vector of `Trade` structs representing the trades executed by the strategy.
pub fn run(candles: &[CandleRecord], params: &MeanReversionParams) -> Vec<Trade> {
    let mut trades: Vec<Trade> = Vec::new();
    let mut i = params.ma_period;
    while i < candles.len() {
        let ma = candles[i - params.ma_period..i]
            .iter()
            .fold(0.0, |acc, c| acc + c.close)
            / params.ma_period as f64;
        let close = candles[i].close;
        let pct_below = (close - ma) / ma;
        if pct_below < params.entry_threshold {
            let entry_time = candles[i].timestamp;
            let entry_price = close;
            let mut in_trade = true;
            for j in i + 1..candles.len() {
                let exit_price = candles[j].close;
                let exit_time = candles[j].timestamp;
                let pnl = (exit_price - entry_price) / entry_price;
                if pnl > params.exit_threshold || pnl < params.stop_loss {
                    in_trade = false;
                    trades.push(Trade {
                        direction: Direction::Long,
                        entry_price,
                        exit_price,
                        entry_time,
                        exit_time,
                        pnl_percent: pnl,
                        entry_reason: EntryReason::BelowMA {
                            ma_value: ma,
                            deviation_pct: pct_below,
                        },
                        exit_reason: if pnl > params.exit_threshold {
                            ExitReason::TakeProfit
                        } else {
                            ExitReason::StopLoss
                        },
                    });
                    i = j + 1;
                    break;
                }
            }
            if in_trade {
                trades.push(Trade {
                    direction: Direction::Long,
                    entry_price,
                    exit_price: candles.last().unwrap().close,
                    entry_time,
                    exit_time: candles.last().unwrap().timestamp,
                    pnl_percent: (candles.last().unwrap().close - entry_price) / entry_price,
                    entry_reason: EntryReason::BelowMA {
                        ma_value: ma,
                        deviation_pct: pct_below,
                    },
                    exit_reason: ExitReason::EndOfData,
                });
                break;
            }
        } else {
            i += 1;
        }
    }
    trades
}

pub fn check_entry(closes: &[f64], params: &MeanReversionParams) -> MRSignal {
    if closes.len() < params.ma_period {
        return MRSignal::None;
    }

    let ma = closes[closes.len() - params.ma_period..]
        .iter()
        .sum::<f64>()
        / params.ma_period as f64;

    let close = closes[closes.len() - 1];
    let deviation = (close / ma) / ma;

    if deviation < params.entry_threshold {
        MRSignal::Enter {
            ma_value: ma,
            deviation_pct: deviation,
        }
    } else {
        MRSignal::None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Duration;

    fn make_candle(price: f64, minutes_offset: i64) -> CandleRecord {
        CandleRecord {
            instrument: String::from("EUR_USD"),
            granularity: String::from("M1"),
            timestamp: Utc::now() - Duration::minutes(minutes_offset),
            open: price,
            high: price,
            low: price,
            close: price,
            volume: 0,
            complete: true,
        }
    }

    #[test]
    fn test_mean_reversion_take_profit() {
        // Create 20 candles, hovering around 1.1650
        // 3 candles dropping to 1.1590
        // 5 candles recovering back to 1.1640
        let candles = vec![
            make_candle(1.1650, 0),
            make_candle(1.1648, 1),
            make_candle(1.1652, 2),
            make_candle(1.1649, 3),
            make_candle(1.1651, 4),
            make_candle(1.1650, 5),
            make_candle(1.1647, 6),
            make_candle(1.1653, 7),
            make_candle(1.1650, 8),
            make_candle(1.1651, 9),
            make_candle(1.1649, 10),
            make_candle(1.1650, 11),
            make_candle(1.1652, 12),
            make_candle(1.1648, 13),
            make_candle(1.1650, 14),
            make_candle(1.1651, 15),
            make_candle(1.1649, 16),
            make_candle(1.1650, 17),
            make_candle(1.1652, 18),
            make_candle(1.1650, 19),
            make_candle(1.1620, 20),
            make_candle(1.1600, 21),
            make_candle(1.1590, 22),
            make_candle(1.1610, 23),
            make_candle(1.1630, 24),
            make_candle(1.1645, 25),
            make_candle(1.1650, 26),
        ];
        let params = MeanReversionParams {
            ma_period: 20,
            entry_threshold: -0.002,
            exit_threshold: 0.002,
            stop_loss: -0.01,
        };
        let trades = run(&candles, &params);
        assert_eq!(trades.len(), 1);
        assert!(trades[0].pnl_percent > 0.0);
        assert!(matches!(trades[0].exit_reason, ExitReason::TakeProfit));
    }

    #[test]
    fn test_mean_reversion_stop_loss() {
        // Create 20 candles, hovering around 1.1650, create data that will trigger a stop loss exit
        let candles = vec![
            // 20 stable candles to establish MA around 1.1650
            make_candle(1.1650, 0),
            make_candle(1.1648, 1),
            make_candle(1.1652, 2),
            make_candle(1.1649, 3),
            make_candle(1.1651, 4),
            make_candle(1.1650, 5),
            make_candle(1.1647, 6),
            make_candle(1.1653, 7),
            make_candle(1.1650, 8),
            make_candle(1.1651, 9),
            make_candle(1.1649, 10),
            make_candle(1.1650, 11),
            make_candle(1.1652, 12),
            make_candle(1.1648, 13),
            make_candle(1.1650, 14),
            make_candle(1.1651, 15),
            make_candle(1.1649, 16),
            make_candle(1.1650, 17),
            make_candle(1.1652, 18),
            make_candle(1.1650, 19),
            // Drop triggers entry
            make_candle(1.1620, 20),
            // Price keeps falling — no recovery
            make_candle(1.1600, 21),
            make_candle(1.1570, 22),
            make_candle(1.1540, 23),
            make_candle(1.1500, 24),
        ];
        let params = MeanReversionParams {
            ma_period: 20,
            entry_threshold: -0.002,
            exit_threshold: 0.002,
            stop_loss: -0.01,
        };
        let trades = run(&candles, &params);
        assert_eq!(trades.len(), 1);
        assert!(trades[0].pnl_percent < 0.0);
        assert!(matches!(trades[0].exit_reason, ExitReason::StopLoss));
    }

    #[test]
    fn test_mean_reversion_end_of_data() {
        // Create 20 candles, hovering around 1.1650, but no clear exit point, so trigger END_OF_DATA exit
        let candles = vec![
            make_candle(1.1650, 0),
            make_candle(1.1648, 1),
            make_candle(1.1652, 2),
            make_candle(1.1649, 3),
            make_candle(1.1651, 4),
            make_candle(1.1650, 5),
            make_candle(1.1647, 6),
            make_candle(1.1653, 7),
            make_candle(1.1650, 8),
            make_candle(1.1651, 9),
            make_candle(1.1649, 10),
            make_candle(1.1650, 11),
            make_candle(1.1652, 12),
            make_candle(1.1648, 13),
            make_candle(1.1650, 14),
            make_candle(1.1648, 15),
            make_candle(1.1650, 16),
            make_candle(1.1649, 17),
            make_candle(1.1651, 18),
            make_candle(1.1650, 19),
            make_candle(1.1620, 20), // entry
            make_candle(1.1615, 21), // P&L = -0.04%  (not near -1%)
            make_candle(1.1618, 22), // P&L = -0.02%
            make_candle(1.1622, 23), // P&L = +0.02% (not near +0.2%)
        ];
        let params = MeanReversionParams {
            ma_period: 20,
            entry_threshold: -0.002,
            exit_threshold: 0.002,
            stop_loss: -0.01,
        };
        let trades = run(&candles, &params);
        assert_eq!(trades.len(), 1);
        assert!(matches!(trades[0].exit_reason, ExitReason::EndOfData));
    }
}
