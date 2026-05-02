use crate::engine::types::{Candle, Direction, EntryReason, ExitReason, Trade};

pub enum TFSignal {
    EnterLong { fast_ma: f64, slow_ma: f64 },
    EnterShort { fast_ma: f64, slow_ma: f64 },
    ExitTrendReversal { fast_ma: f64, slow_ma: f64 },
    None,
}

pub struct TrendFollowingParams {
    pub fast_period: usize,       // e.g., 10
    pub slow_period: usize,       // e.g., 50
    pub stop_loss: f64,           // e.g., -0.02 (-2%)
    pub take_profit: Option<f64>, // e.g., Some(0.05) or None to ride the trend
}

pub fn run(candles: &[Candle], params: &TrendFollowingParams) -> Vec<Trade> {
    let mut trades: Vec<Trade> = Vec::new();
    // We need at least slow_period + 1 candles to detect a crossover
    // (we compare current vs previous candles MA relationship)
    if candles.len() < params.slow_period + 1 {
        return trades;
    }

    let mut i = params.slow_period;

    // Calculate the initial MA relationship so we can detect the first cross
    let mut prev_fast = ma(candles, i, params.fast_period);
    let mut prev_slow = ma(candles, i, params.slow_period);

    i += 1;

    while i < candles.len() {
        let fast = ma(candles, i, params.fast_period);
        let slow = ma(candles, i, params.slow_period);

        // Detect crossover:
        // Previous fast <= slow, CUrrent: fast > slow -> bullish cross -> go long
        // Previous fast >= slow, Current: fast < slow -> bearish cross -> go short
        let bullish_cross = prev_fast <= prev_slow && fast > slow;
        let bearish_cross = prev_fast >= prev_slow && fast < slow;

        if bullish_cross || bearish_cross {
            let direction = if bullish_cross {
                Direction::Long
            } else {
                Direction::Short
            };
            let entry_price = candles[i].close;
            let entry_time = candles[i].time;
            let entry_reason = if bullish_cross {
                EntryReason::CrossAbove {
                    fast_ma: fast,
                    slow_ma: slow,
                }
            } else {
                EntryReason::CrossBelow {
                    fast_ma: fast,
                    slow_ma: slow,
                }
            };

            // Now scan forward for an exit
            let mut exited = false;

            for j in i + 1..candles.len() {
                let j_fast = ma(candles, j, params.fast_period);
                let j_slow = ma(candles, j, params.slow_period);
                let exit_price = candles[j].close;
                let exit_time = candles[j].time;

                let pnl = match direction {
                    Direction::Long => (exit_price - entry_price) / entry_price,
                    Direction::Short => (entry_price - exit_price) / entry_price,
                };

                let mut exit_reason = ExitReason::EndOfData; // placeholder, gets overwritten

                let should_exit = if pnl < params.stop_loss {
                    exit_reason = ExitReason::StopLoss;
                    true
                } else if let Some(tp) = params.take_profit {
                    if pnl > tp {
                        exit_reason = ExitReason::TakeProfit;
                        true
                    } else {
                        false
                    }
                } else {
                    false
                };

                let trend_reversed = match direction {
                    Direction::Long => j_fast < j_slow,
                    Direction::Short => j_fast > j_slow,
                };

                if should_exit || trend_reversed {
                    if trend_reversed && !should_exit {
                        exit_reason = ExitReason::TrendReversal;
                    }

                    trades.push(Trade {
                        direction,
                        entry_price,
                        exit_price,
                        entry_time,
                        exit_time,
                        pnl_percent: pnl,
                        entry_reason,
                        exit_reason,
                    });
                    i = j + 1;
                    exited = true;
                    break;
                }
            }

            if !exited {
                let exit_price = candles[candles.len() - 1].close;
                let exit_time = candles[candles.len() - 1].time;
                let exit_reason = ExitReason::EndOfData;
                let pnl = match direction {
                    Direction::Long => (exit_price - entry_price) / entry_price,
                    Direction::Short => (entry_price - exit_price) / entry_price,
                };
                trades.push(Trade {
                    direction,
                    pnl_percent: pnl,
                    entry_reason: EntryReason::CrossAbove {
                        fast_ma: prev_fast,
                        slow_ma: prev_slow,
                    },
                    entry_price,
                    entry_time,
                    exit_price,
                    exit_time,
                    exit_reason,
                });
                i = candles.len();
            }

            // Update prev MAs to where we exited
            if i < candles.len() {
                prev_fast = ma(candles, i.min(candles.len() - 1), params.fast_period);
                prev_slow = ma(candles, i.min(candles.len() - 1), params.slow_period);
            }
        } else {
            prev_fast = fast;
            prev_slow = slow;
            i += 1;
        }
    }
    trades
}

pub fn check_entry(closes: &[f64], params: &TrendFollowingParams) -> TFSignal {
    if closes.len() < params.slow_period + 1 {
        return TFSignal::None;
    }

    let len = closes.len();
    let fast = closes[len - params.fast_period..].iter().sum::<f64>() / params.fast_period as f64;
    let slow = closes[len - params.slow_period..].iter().sum::<f64>() / params.slow_period as f64;

    let prev = &closes[..len - 1];
    let prev_fast =
        prev[prev.len() - params.fast_period..].iter().sum::<f64>() / params.fast_period as f64;
    let prev_slow =
        prev[prev.len() - params.slow_period..].iter().sum::<f64>() / params.slow_period as f64;

    let bullish_cross = prev_fast <= prev_slow && fast > slow;
    let bearish_cross = prev_fast >= prev_slow && fast < slow;

    if bullish_cross {
        TFSignal::EnterLong {
            fast_ma: fast,
            slow_ma: slow,
        }
    } else if bearish_cross {
        TFSignal::EnterShort {
            fast_ma: fast,
            slow_ma: slow,
        }
    } else {
        TFSignal::None
    }
}

pub fn check_exit(closes: &[f64], params: &TrendFollowingParams, is_long: bool) -> TFSignal {
    if closes.len() < params.slow_period {
        return TFSignal::None;
    }

    let len = closes.len();
    let fast = closes[len - params.fast_period..].iter().sum::<f64>() / params.fast_period as f64;
    let slow = closes[len - params.slow_period..].iter().sum::<f64>() / params.slow_period as f64;

    let reversed = if is_long { fast < slow } else { fast > slow };

    if reversed {
        TFSignal::ExitTrendReversal {
            fast_ma: fast,
            slow_ma: slow,
        }
    } else {
        TFSignal::None
    }
}

fn ma(candles: &[Candle], end: usize, period: usize) -> f64 {
    candles[end - period..end]
        .iter()
        .map(|c| c.close)
        .sum::<f64>()
        / period as f64
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, Utc};

    fn make_candle(price: f64, hours_offset: i64) -> Candle {
        let base = Utc::now();
        Candle {
            time: base + Duration::hours(hours_offset),
            open: price,
            high: price,
            low: price,
            close: price,
            volume: 100,
        }
    }

    #[test]
    fn test_bullish_cross_take_profit() {
        // 50 candles with slow downtrend (fast MA below slow MA)
        // then price starts rising (fast MA crosses above slow MA)
        // then continues up to hit take profit
        let mut candles = Vec::new();

        // Phase 1: declining prices — fast MA stays below slow MA
        for i in 0..50 {
            candles.push(make_candle(1.2000 - (i as f64 * 0.0005), i));
        }
        // At this point price is around 1.1755

        // Phase 2: sharp reversal upward — fast MA will cross above slow MA
        for i in 50..70 {
            candles.push(make_candle(1.1755 + ((i - 50) as f64 * 0.002), i));
        }
        // At this point price is around 1.2155

        // Phase 3: continued rise to hit take profit
        for i in 70..90 {
            candles.push(make_candle(1.2155 + ((i - 70) as f64 * 0.002), i));
        }

        let params = TrendFollowingParams {
            fast_period: 10,
            slow_period: 30,
            stop_loss: -0.05,
            take_profit: Some(0.03),
        };

        let trades = run(&candles, &params);
        assert!(!trades.is_empty(), "Should have at least one trade");

        // Find the first long trade
        let long_trade = trades
            .iter()
            .find(|t| matches!(t.direction, Direction::Long));
        assert!(long_trade.is_some(), "Should have a long trade");

        let trade = long_trade.unwrap();
        assert!(trade.pnl_percent > 0.0, "Long trade should be profitable");
        assert!(
            matches!(trade.exit_reason, ExitReason::TakeProfit),
            "Should exit on take profit, got {:?}",
            trade.exit_reason
        );
    }

    #[test]
    fn test_trend_reversal_exit() {
        let mut candles = Vec::new();

        // Downtrend — establishes fast < slow clearly
        for i in 0..50 {
            candles.push(make_candle(1.3000 - (i as f64 * 0.001), i));
        }
        // Price around 1.2500, fast MA well below slow MA

        // Sharp rise — fast MA crosses above slow MA
        for i in 50..80 {
            candles.push(make_candle(1.2500 + ((i - 50) as f64 * 0.004), i));
        }
        // Price around 1.3700

        // Sharp drop — fast MA crosses back below slow MA
        for i in 80..120 {
            candles.push(make_candle(1.3700 - ((i - 80) as f64 * 0.004), i));
        }
        // Price around 1.2100

        let params = TrendFollowingParams {
            fast_period: 5,
            slow_period: 20,
            stop_loss: -0.15,
            take_profit: None,
        };

        let trades = run(&candles, &params);
        dbg!(&trades);
        assert!(!trades.is_empty(), "Should have at least one trade");

        let long_reversal = trades.iter().find(|t| {
            matches!(t.direction, Direction::Long)
                && matches!(t.exit_reason, ExitReason::TrendReversal)
        });
        assert!(
            long_reversal.is_some(),
            "Should have a long trade that exited on trend reversal. Trades: {:?}",
            trades
                .iter()
                .map(|t| (&t.direction, &t.exit_reason, t.pnl_percent))
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn test_stop_loss() {
        let mut candles = Vec::new();

        // Downtrend
        for i in 0..50 {
            candles.push(make_candle(1.3000 - (i as f64 * 0.001), i));
        }

        // Rise — triggers bullish cross
        for i in 50..75 {
            candles.push(make_candle(1.2500 + ((i - 50) as f64 * 0.004), i));
        }
        // Price around 1.3500

        // Flash crash well below entry price (~1.27)
        candles.push(make_candle(1.20, 75));

        let params = TrendFollowingParams {
            fast_period: 5,
            slow_period: 20,
            stop_loss: -0.02,
            take_profit: None,
        };

        let trades = run(&candles, &params);
        dbg!(&trades);

        let stop_trade = trades.iter().find(|t| {
            matches!(t.direction, Direction::Long) && matches!(t.exit_reason, ExitReason::StopLoss)
        });
        assert!(
            stop_trade.is_some(),
            "Should have a long trade stopped out. Trades: {:?}",
            trades
                .iter()
                .map(|t| (&t.direction, &t.exit_reason, t.pnl_percent))
                .collect::<Vec<_>>()
        );
        assert!(stop_trade.unwrap().pnl_percent < 0.0);
    }
}
