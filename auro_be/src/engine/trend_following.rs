use crate::engine::live::{MOVE_TO_BREAKEVEN_PCT, TRAILING_DISTANCE_PCT};
use crate::engine::types::{Candle, Direction, EntryReason, ExitReason, StopLossState, Trade};

pub enum TFSignal {
    EnterLong { fast_ma: f64, slow_ma: f64 },
    EnterShort { fast_ma: f64, slow_ma: f64 },
    ExitTrendReversal { fast_ma: f64, slow_ma: f64 },
    None,
}

#[derive(serde::Deserialize)]
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

            // Trade management state — mirrors evaluate_trade_management in live.rs.
            // Initial: SL at entry +/- params.stop_loss
            // Breakeven: SL moves to entry once pct_in_profit >= MOVE_TO_BREAKEVEN_PCT
            // Trailing: SL trails high-water-mark by TRAILING_DISTANCE_PCT once
            //           pct_in_profit >= MOVE_TO_BREAKEVEN_PCT + TRAILING_DISTANCE_PCT.
            let mut sl_state = StopLossState::Initial;
            let mut current_sl_price = match direction {
                Direction::Long => entry_price * (1.0 + params.stop_loss),
                Direction::Short => entry_price * (1.0 - params.stop_loss),
            };
            let mut high_water_mark = entry_price;
            let trailing_trigger = MOVE_TO_BREAKEVEN_PCT + TRAILING_DISTANCE_PCT;

            // Now scan forward for an exit
            let mut exited = false;

            for j in i + 1..candles.len() {
                let j_fast = ma(candles, j, params.fast_period);
                let j_slow = ma(candles, j, params.slow_period);
                let close = candles[j].close;
                let exit_time = candles[j].time;

                let pct_in_profit = match direction {
                    Direction::Long => (close - entry_price) / entry_price,
                    Direction::Short => (entry_price - close) / entry_price,
                };

                // State transitions based on this bar's close
                match sl_state {
                    StopLossState::Initial => {
                        if pct_in_profit >= MOVE_TO_BREAKEVEN_PCT {
                            sl_state = StopLossState::Breakeven;
                            current_sl_price = entry_price;
                        }
                    }
                    StopLossState::Breakeven => {
                        if pct_in_profit >= trailing_trigger {
                            sl_state = StopLossState::Trailing;
                            high_water_mark = close;
                            let distance = close * TRAILING_DISTANCE_PCT;
                            current_sl_price = match direction {
                                Direction::Long => close - distance,
                                Direction::Short => close + distance,
                            };
                        }
                    }
                    StopLossState::Trailing => {
                        let is_more_favorable = match direction {
                            Direction::Long => close > high_water_mark,
                            Direction::Short => close < high_water_mark,
                        };
                        if is_more_favorable {
                            high_water_mark = close;
                            let distance = close * TRAILING_DISTANCE_PCT;
                            current_sl_price = match direction {
                                Direction::Long => close - distance,
                                Direction::Short => close + distance,
                            };
                        }
                    }
                    StopLossState::NotApplicable => {}
                }

                // SL hit (close-based, against the current dynamic SL price)
                let sl_hit = match direction {
                    Direction::Long => close <= current_sl_price,
                    Direction::Short => close >= current_sl_price,
                };

                let tp_hit = match params.take_profit {
                    Some(tp) => pct_in_profit >= tp,
                    None => false,
                };

                let trend_reversed = match direction {
                    Direction::Long => j_fast < j_slow,
                    Direction::Short => j_fast > j_slow,
                };

                if sl_hit || tp_hit || trend_reversed {
                    // Exit at the actual fill price for the exit type, not the bar's close.
                    // SL: normally fills at the SL price, EXCEPT when the bar gapped past
                    //     the SL (e.g., weekend gap). Then fill at the bar's open
                    //     ("strict fill rule" / pessimistic validation — assumes the worst
                    //     plausible outcome instead of the SL price OANDA couldn't have
                    //     reached during the gap).
                    // TP: always fills at TP price (we don't claim gap upside — also
                    //     pessimistic).
                    let bar_open = candles[j].open;
                    let (exit_price, exit_reason) = if sl_hit {
                        let reason = match sl_state {
                            StopLossState::Trailing => ExitReason::TrailingStop,
                            _ => ExitReason::StopLoss,
                        };
                        let gap_past_sl = match direction {
                            Direction::Long => bar_open <= current_sl_price,
                            Direction::Short => bar_open >= current_sl_price,
                        };
                        let fill_price = if gap_past_sl {
                            bar_open
                        } else {
                            current_sl_price
                        };
                        (fill_price, reason)
                    } else if tp_hit {
                        let tp = params.take_profit.unwrap();
                        let tp_price = match direction {
                            Direction::Long => entry_price * (1.0 + tp),
                            Direction::Short => entry_price * (1.0 - tp),
                        };
                        (tp_price, ExitReason::TakeProfit)
                    } else {
                        (close, ExitReason::TrendReversal)
                    };

                    let pnl = match direction {
                        Direction::Long => (exit_price - entry_price) / entry_price,
                        Direction::Short => (entry_price - exit_price) / entry_price,
                    };

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
        // Price around 1.2500

        // Modest rise — triggers cross but stays under 1.5% BE trigger
        for i in 50..80 {
            candles.push(make_candle(1.2500 + ((i - 50) as f64 * 0.0008), i));
        }
        // Price around 1.274 — ~1% above cross-point entry

        // Slow decline — eventually flips MA cross without hitting SL
        for i in 80..130 {
            candles.push(make_candle(1.2740 - ((i - 80) as f64 * 0.0008), i));
        }

        let params = TrendFollowingParams {
            fast_period: 5,
            slow_period: 20,
            stop_loss: -0.15,
            take_profit: None,
        };

        let trades = run(&candles, &params);
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
    fn test_initial_stop_loss() {
        // Trade enters, drops immediately — never gets to BE trigger.
        let mut candles = Vec::new();

        // Downtrend
        for i in 0..50 {
            candles.push(make_candle(1.3000 - (i as f64 * 0.001), i));
        }

        // Modest rise — triggers cross but stays under 1.5% BE trigger
        for i in 50..65 {
            candles.push(make_candle(1.2500 + ((i - 50) as f64 * 0.001), i));
        }
        // Price around 1.265

        // Intra-bar flash crash: opens normally then crashes through SL during the
        // bar (no weekend gap). SL should fill at the SL price, not at open.
        let base_time = Utc::now();
        candles.push(Candle {
            time: base_time + Duration::hours(65),
            open: 1.265, // above the ~1.2348 SL
            high: 1.265,
            low: 1.20,
            close: 1.20, // bar closed below SL
            volume: 100,
        });

        let params = TrendFollowingParams {
            fast_period: 5,
            slow_period: 20,
            stop_loss: -0.02,
            take_profit: None,
        };

        let trades = run(&candles, &params);

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
        // Intra-bar SL fills at the SL price — should be ~-2.0%
        let pnl = stop_trade.unwrap().pnl_percent;
        assert!(
            (pnl - (-0.02)).abs() < 0.0001,
            "Initial SL should fill at exactly -2%, got {}",
            pnl
        );
    }

    #[test]
    fn test_weekend_gap_fills_at_open_not_sl() {
        // "Strict fill rule": when a bar's open gaps past the SL, the trade
        // should fill at the bar's OPEN (worse), not the SL price.
        let mut candles = Vec::new();

        // Downtrend
        for i in 0..50 {
            candles.push(make_candle(1.3000 - (i as f64 * 0.001), i));
        }

        // Modest rise — triggers cross but stays under BE trigger
        for i in 50..65 {
            candles.push(make_candle(1.2500 + ((i - 50) as f64 * 0.001), i));
        }
        // Entry around 1.260, Initial SL at 1.2348 (entry * 0.98)

        // Gap-down bar: opens at 1.20 (well below SL of 1.2348)
        let base_time = Utc::now();
        candles.push(Candle {
            time: base_time + Duration::hours(65),
            open: 1.20,
            high: 1.20,
            low: 1.18,
            close: 1.19,
            volume: 100,
        });

        let params = TrendFollowingParams {
            fast_period: 5,
            slow_period: 20,
            stop_loss: -0.02,
            take_profit: None,
        };

        let trades = run(&candles, &params);

        let stop_trade = trades
            .iter()
            .find(|t| matches!(t.exit_reason, ExitReason::StopLoss))
            .expect("Should have a StopLoss exit");

        // Without gap modeling: exit at 1.2348, pnl ≈ -2.0%.
        // With gap modeling: exit at the gap-down open (1.20), pnl much worse.
        assert_eq!(
            stop_trade.exit_price, 1.20,
            "Expected fill at gap-down open (1.20), got {}",
            stop_trade.exit_price
        );
        assert!(
            stop_trade.pnl_percent < -0.04,
            "Gap fill should be worse than -2% SL, got {}",
            stop_trade.pnl_percent
        );
    }

    #[test]
    fn test_breakeven_stop_locks_zero_loss() {
        // Trade enters, rises >1.5% (triggering BE), then a single sharp drop bar
        // hits the BE-level SL (entry price) before MAs flip.
        let mut candles = Vec::new();

        // Downtrend
        for i in 0..50 {
            candles.push(make_candle(1.3000 - (i as f64 * 0.001), i));
        }

        // Long, sustained rise — gives BE plenty of room to fire and slow MA to climb
        for i in 50..90 {
            candles.push(make_candle(1.2500 + ((i - 50) as f64 * 0.001), i));
        }
        // Peak ~1.289 at bar 89, ~2.3% above cross-point entry of 1.260

        // Single sharp drop bar to just below entry — fast MA still elevated by recent highs
        candles.push(make_candle(1.255, 90));

        let params = TrendFollowingParams {
            fast_period: 5,
            slow_period: 20,
            stop_loss: -0.05, // wide initial SL — won't get hit before BE/trailing
            take_profit: None,
        };

        let trades = run(&candles, &params);

        let long_trade = trades
            .iter()
            .find(|t| matches!(t.direction, Direction::Long))
            .expect("Should have a long trade");

        assert!(
            matches!(long_trade.exit_reason, ExitReason::StopLoss),
            "Expected StopLoss (BE-level) exit, got {:?}. Trades: {:?}",
            long_trade.exit_reason,
            trades
                .iter()
                .map(|t| (&t.direction, &t.exit_reason, t.pnl_percent))
                .collect::<Vec<_>>()
        );
        assert!(
            long_trade.pnl_percent.abs() < 0.005,
            "BE stop should produce near-zero pnl, got {}",
            long_trade.pnl_percent
        );
    }

    #[test]
    fn test_trailing_stop_locks_profit() {
        // Trade enters, rises >4% (triggering trailing), then a few sharp drop bars
        // hit the trailing SL before MAs flip.
        let mut candles = Vec::new();

        // Downtrend
        for i in 0..50 {
            candles.push(make_candle(1.3000 - (i as f64 * 0.001), i));
        }

        // Long, strong rise — well past trailing trigger
        for i in 50..100 {
            candles.push(make_candle(1.2500 + ((i - 50) as f64 * 0.0015), i));
        }
        // Peak ~1.3235 at bar 99, ~4.6% above entry

        // Sharp 3-bar drop — fast enough that the trailing SL fires before MAs flip
        for i in 100..104 {
            candles.push(make_candle(1.3250 - ((i - 100) as f64 * 0.018), i));
        }
        // Bars 100-103: 1.325, 1.307, 1.289, 1.271

        let params = TrendFollowingParams {
            fast_period: 5,
            slow_period: 20,
            stop_loss: -0.05, // wide initial SL — never reached
            take_profit: None,
        };

        let trades = run(&candles, &params);

        let long_trade = trades
            .iter()
            .find(|t| matches!(t.direction, Direction::Long))
            .expect("Should have a long trade");

        assert!(
            matches!(long_trade.exit_reason, ExitReason::TrailingStop),
            "Expected TrailingStop exit, got {:?}. Trades: {:?}",
            long_trade.exit_reason,
            trades
                .iter()
                .map(|t| (&t.direction, &t.exit_reason, t.pnl_percent))
                .collect::<Vec<_>>()
        );
        assert!(
            long_trade.pnl_percent > 0.0,
            "Trailing stop should lock in profit, got {}",
            long_trade.pnl_percent
        );
    }
}
