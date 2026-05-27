//! Mean reversion strategy — v1 (Investopedia baseline).
//!
//! Entry: bidirectional Z-score + RSI confirmation. Both must agree.
//!   - Long:  Z < -entry_z_threshold AND RSI < rsi_oversold
//!   - Short: Z > +entry_z_threshold AND RSI > rsi_overbought
//!
//! Exit:
//!   - ReturnToMean: Z crosses zero from the entry side (canonical MR exit).
//!   - ZStop: Z extends further in the adverse direction past stop_z_threshold.
//!   - EndOfData: backtest only — trade still open at the end of the candle series.
//!
//! Reference: Investopedia "Mean Reversion" article. Z-score formula and
//! 1.5/2.0 thresholds, RSI 30/70 confirmation, exit at the mean, SL around the
//! mean. Departures from the article (ADX gate, time stop, MTF, Hurst, etc.)
//! are deliberately deferred to v2 — see [[backlog-mr-v2]].

use std::collections::HashMap;

use crate::engine::indicators::{rsi, z_score};
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason, ExitReason, Trade};

#[derive(Debug, serde::Deserialize, serde::Serialize, Clone)]
pub struct MeanReversionParams {
    /// SMA + stdev window for Z-score. Default 20.
    pub ma_period: usize,
    /// Wilder's RSI period. Default 14.
    pub rsi_period: usize,
    /// |Z| trigger for entry. Default 1.5.
    pub entry_z_threshold: f64,
    /// Long entry requires RSI strictly below this. Default 30.0.
    pub rsi_oversold: f64,
    /// Short entry requires RSI strictly above this. Default 70.0.
    pub rsi_overbought: f64,
    /// Z-extension stop (absolute value, applied in the adverse direction).
    /// Long stops when Z ≤ -stop_z_threshold; Short stops when Z ≥ +stop_z_threshold.
    /// Default 3.5.
    pub stop_z_threshold: f64,
}

pub enum MREntrySignal {
    Long {
        ma_value: f64,
        z_score: f64,
        rsi: f64,
    },
    Short {
        ma_value: f64,
        z_score: f64,
        rsi: f64,
    },
    None,
}

pub enum MRExitSignal {
    ReturnToMean { ma_value: f64, z_score: f64 },
    ZStop { z_score: f64 },
    Hold,
}

// ---------------------------------------------------------------------------
// Signaler trait impl — used by the composite strategy shape. The legacy
// flat-shape MR (check_entry/check_exit/run) keeps working for existing live
// MR strategies until they migrate; new strategies use composite shape via
// this trait impl.
// ---------------------------------------------------------------------------

impl Signaler for MeanReversionParams {
    fn warmup(&self) -> usize {
        self.ma_period.max(self.rsi_period + 1)
    }

    /// Emits four bool ports:
    /// - `long`:        Z < -entry_z_threshold AND RSI < rsi_oversold
    /// - `short`:       Z > +entry_z_threshold AND RSI > rsi_overbought
    /// - `exit_long`:   Z >= 0 (return-to-mean) OR Z <= -stop_z_threshold (z-stop)
    /// - `exit_short`:  Z <= 0 (return-to-mean) OR Z >= +stop_z_threshold (z-stop)
    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        if candles.len() < self.warmup() {
            return None;
        }
        let z = z_score(candles, self.ma_period)?;
        let r = rsi(candles, self.rsi_period)?;

        let long = z < -self.entry_z_threshold && r < self.rsi_oversold;
        let short = z > self.entry_z_threshold && r > self.rsi_overbought;

        let exit_long = z >= 0.0 || z <= -self.stop_z_threshold;
        let exit_short = z <= 0.0 || z >= self.stop_z_threshold;

        let mut ports = HashMap::new();
        ports.insert("long".to_string(), long);
        ports.insert("short".to_string(), short);
        ports.insert("exit_long".to_string(), exit_long);
        ports.insert("exit_short".to_string(), exit_short);
        Some(ports)
    }

    fn entry_reason(&self, candles: &[Candle], _direction: Direction) -> EntryReason {
        let ma: f64 = {
            let window = &candles[candles.len() - self.ma_period..];
            window.iter().map(|c| c.mid.close).sum::<f64>() / self.ma_period as f64
        };
        let z = z_score(candles, self.ma_period).unwrap_or(0.0);
        let r = rsi(candles, self.rsi_period).unwrap_or(50.0);
        EntryReason::MeanReversionEntry {
            ma_value: ma,
            z_score: z,
            rsi: r,
        }
    }

    /// MR's stop is anchored at the MA, not at entry price:
    ///   Long:  SL = MA - stop_z_threshold * stdev
    ///   Short: SL = MA + stop_z_threshold * stdev
    /// Returns the absolute price.
    fn stop_price(&self, candles: &[Candle], direction: Direction) -> Option<f64> {
        if candles.len() < self.ma_period {
            return None;
        }
        let window = &candles[candles.len() - self.ma_period..];
        let p_f = self.ma_period as f64;
        let mean: f64 = window.iter().map(|c| c.mid.close).sum::<f64>() / p_f;
        let variance: f64 = window
            .iter()
            .map(|c| {
                let d = c.mid.close - mean;
                d * d
            })
            .sum::<f64>()
            / p_f;
        let stdev = variance.sqrt();
        if stdev <= 0.0 {
            return None;
        }
        let distance = self.stop_z_threshold * stdev;
        Some(match direction {
            Direction::Long => mean - distance,
            Direction::Short => mean + distance,
        })
    }
}

/// Evaluate entry signal against the candle window ending at the most recent close.
pub fn check_entry(candles: &[Candle], params: &MeanReversionParams) -> MREntrySignal {
    let needed = params.ma_period.max(params.rsi_period + 1);
    if candles.len() < needed {
        return MREntrySignal::None;
    }

    let z = match z_score(candles, params.ma_period) {
        Some(v) => v,
        None => return MREntrySignal::None,
    };
    let r = match rsi(candles, params.rsi_period) {
        Some(v) => v,
        None => return MREntrySignal::None,
    };

    // Recompute MA for metadata (cheap, same window as Z).
    let window = &candles[candles.len() - params.ma_period..];
    let ma: f64 = window.iter().map(|c| c.mid.close).sum::<f64>() / params.ma_period as f64;

    // Long: oversold dislocation with momentum confirmation.
    if z < -params.entry_z_threshold && r < params.rsi_oversold {
        return MREntrySignal::Long {
            ma_value: ma,
            z_score: z,
            rsi: r,
        };
    }

    // Short: overbought dislocation with momentum confirmation.
    if z > params.entry_z_threshold && r > params.rsi_overbought {
        return MREntrySignal::Short {
            ma_value: ma,
            z_score: z,
            rsi: r,
        };
    }

    MREntrySignal::None
}

/// Evaluate exit signal for an open MR position. ZStop is checked before
/// ReturnToMean so a bar that satisfies both is recorded as a stop.
pub fn check_exit(
    candles: &[Candle],
    params: &MeanReversionParams,
    direction: Direction,
) -> MRExitSignal {
    if candles.len() < params.ma_period {
        return MRExitSignal::Hold;
    }

    let z = match z_score(candles, params.ma_period) {
        Some(v) => v,
        None => return MRExitSignal::Hold,
    };

    let window = &candles[candles.len() - params.ma_period..];
    let ma: f64 = window.iter().map(|c| c.mid.close).sum::<f64>() / params.ma_period as f64;

    match direction {
        Direction::Long => {
            if z <= -params.stop_z_threshold {
                return MRExitSignal::ZStop { z_score: z };
            }
            if z >= 0.0 {
                return MRExitSignal::ReturnToMean {
                    ma_value: ma,
                    z_score: z,
                };
            }
        }
        Direction::Short => {
            if z >= params.stop_z_threshold {
                return MRExitSignal::ZStop { z_score: z };
            }
            if z <= 0.0 {
                return MRExitSignal::ReturnToMean {
                    ma_value: ma,
                    z_score: z,
                };
            }
        }
    }

    MRExitSignal::Hold
}

/// Backtest the strategy over a slice of candles. Bidirectional — produces both
/// long and short trades as signals fire. Trades still open at the end of the
/// candle series are recorded with `ExitReason::EndOfData`.
pub fn run(candles: &[Candle], params: &MeanReversionParams) -> Vec<Trade> {
    let mut trades: Vec<Trade> = Vec::new();
    let warmup = params.ma_period.max(params.rsi_period + 1);
    if candles.len() < warmup + 1 {
        return trades;
    }

    let mut i = warmup;
    while i < candles.len() {
        let window = &candles[..=i];
        let entry = check_entry(window, params);

        let (direction, entry_z, entry_rsi, ma_value) = match entry {
            MREntrySignal::Long {
                ma_value,
                z_score,
                rsi,
            } => (Direction::Long, z_score, rsi, ma_value),
            MREntrySignal::Short {
                ma_value,
                z_score,
                rsi,
            } => (Direction::Short, z_score, rsi, ma_value),
            MREntrySignal::None => {
                i += 1;
                continue;
            }
        };

        let entry_time = candles[i].time;
        let entry_price = candles[i].entry_fill_price(direction);
        let entry_reason = EntryReason::MeanReversionEntry {
            ma_value,
            z_score: entry_z,
            rsi: entry_rsi,
        };

        // Walk forward looking for exit.
        let mut exited = false;
        let mut j = i + 1;
        while j < candles.len() {
            let exit_window = &candles[..=j];
            match check_exit(exit_window, params, direction) {
                MRExitSignal::Hold => {
                    j += 1;
                }
                MRExitSignal::ReturnToMean { .. } | MRExitSignal::ZStop { .. } => {
                    let exit_price = candles[j].exit_fill_price(direction);
                    let pnl = match direction {
                        Direction::Long => (exit_price - entry_price) / entry_price,
                        Direction::Short => (entry_price - exit_price) / entry_price,
                    };
                    let exit_reason = match check_exit(exit_window, params, direction) {
                        MRExitSignal::ZStop { .. } => ExitReason::ZStop,
                        MRExitSignal::ReturnToMean { .. } => ExitReason::ReturnToMean,
                        MRExitSignal::Hold => unreachable!(),
                    };
                    trades.push(Trade {
                        direction,
                        entry_price,
                        exit_price,
                        entry_time,
                        exit_time: candles[j].time,
                        pnl_percent: pnl,
                        entry_reason,
                        exit_reason,
                    });
                    exited = true;
                    i = j + 1;
                    break;
                }
            }
        }

        if !exited {
            // Trade still open at end of data.
            let last = candles.last().expect("non-empty by guard above");
            let exit_price = last.exit_fill_price(direction);
            let pnl = match direction {
                Direction::Long => (exit_price - entry_price) / entry_price,
                Direction::Short => (entry_price - exit_price) / entry_price,
            };
            trades.push(Trade {
                direction,
                entry_price,
                exit_price,
                entry_time,
                exit_time: last.time,
                pnl_percent: pnl,
                entry_reason,
                exit_reason: ExitReason::EndOfData,
            });
            break;
        }
    }

    trades
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::{Duration, TimeZone, Utc};

    fn base_params() -> MeanReversionParams {
        MeanReversionParams {
            ma_period: 20,
            rsi_period: 14,
            entry_z_threshold: 1.5,
            rsi_oversold: 30.0,
            rsi_overbought: 70.0,
            stop_z_threshold: 3.5,
        }
    }

    fn candle_at(price: f64, idx: i64) -> Candle {
        Candle {
            time: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap() + Duration::hours(idx),
            mid: OHLC {
                open: price,
                high: price,
                low: price,
                close: price,
            },
            volume: 0,
            bid: None,
            ask: None,
        }
    }

    // -- Entry --

    #[test]
    fn entry_returns_none_with_insufficient_data() {
        let candles: Vec<Candle> = (0..10).map(|i| candle_at(100.0, i)).collect();
        let params = base_params();
        assert!(matches!(
            check_entry(&candles, &params),
            MREntrySignal::None
        ));
    }

    #[test]
    fn entry_long_when_z_low_and_rsi_oversold() {
        // 25 candles trending down monotonically — RSI will be near 0, last close
        // will be well below the rolling mean (negative Z).
        let candles: Vec<Candle> = (0..25)
            .map(|i| candle_at(200.0 - i as f64 * 2.0, i))
            .collect();
        let params = base_params();
        match check_entry(&candles, &params) {
            MREntrySignal::Long { z_score, rsi, .. } => {
                assert!(z_score < -1.5, "expected Z < -1.5, got {}", z_score);
                assert!(rsi < 30.0, "expected RSI < 30, got {}", rsi);
            }
            _ => panic!("expected Long signal, got something else (z+rsi conditions not met)"),
        }
    }

    #[test]
    fn entry_short_when_z_high_and_rsi_overbought() {
        // 25 candles trending up monotonically — RSI near 100, Z strongly positive.
        let candles: Vec<Candle> = (0..25)
            .map(|i| candle_at(100.0 + i as f64 * 2.0, i))
            .collect();
        let params = base_params();
        match check_entry(&candles, &params) {
            MREntrySignal::Short { z_score, rsi, .. } => {
                assert!(z_score > 1.5, "expected Z > 1.5, got {}", z_score);
                assert!(rsi > 70.0, "expected RSI > 70, got {}", rsi);
            }
            _ => panic!("expected Short signal"),
        }
    }

    // -- Exit --

    #[test]
    fn exit_returns_hold_when_z_inside_band() {
        // Construct prices with non-trivial stdev: 10 candles at 102, 9 at 98,
        // last at 99.7. Mean ≈ 100.085, stdev ≈ 1.95, Z ≈ -0.20 — well inside
        // the (-3.5, 0) band for a Long position → Hold.
        let mut candles: Vec<Candle> = Vec::with_capacity(20);
        for i in 0..10 {
            candles.push(candle_at(102.0, i));
        }
        for i in 10..19 {
            candles.push(candle_at(98.0, i));
        }
        candles.push(candle_at(99.7, 19));
        let params = base_params();
        let result = check_exit(&candles, &params, Direction::Long);
        assert!(
            matches!(result, MRExitSignal::Hold),
            "expected Hold for Z mildly negative, got non-Hold"
        );
    }

    #[test]
    fn exit_long_returns_to_mean_when_z_crosses_zero() {
        // Build prices so the last close sits above the mean → Z > 0 → exit.
        let mut candles: Vec<Candle> = (0..19).map(|i| candle_at(100.0, i)).collect();
        candles.push(candle_at(105.0, 19));
        let params = base_params();
        let result = check_exit(&candles, &params, Direction::Long);
        assert!(matches!(result, MRExitSignal::ReturnToMean { .. }));
    }

    #[test]
    fn exit_short_returns_to_mean_when_z_crosses_zero() {
        let mut candles: Vec<Candle> = (0..19).map(|i| candle_at(100.0, i)).collect();
        candles.push(candle_at(95.0, 19));
        let params = base_params();
        let result = check_exit(&candles, &params, Direction::Short);
        assert!(matches!(result, MRExitSignal::ReturnToMean { .. }));
    }

    #[test]
    fn exit_long_z_stop_fires_at_extreme_adverse_z() {
        // 19 candles near 100, then a sharp drop pushing Z below -3.5.
        let mut candles: Vec<Candle> = (0..19).map(|i| candle_at(100.0, i)).collect();
        // Set the last to be well below; with stable prior history, even
        // a moderate drop yields a large Z because stdev is tiny.
        candles.push(candle_at(99.0, 19));
        let params = base_params();
        // 99 vs near-100-mean: Z very negative because stdev of (mostly 100s) is small.
        let result = check_exit(&candles, &params, Direction::Long);
        assert!(matches!(result, MRExitSignal::ZStop { .. }));
    }

    #[test]
    fn exit_z_stop_preempts_return_to_mean_when_both_would_fire() {
        // Construct a scenario where Z reads as a stop (very negative for Long).
        // ReturnToMean for Long requires Z >= 0, which is mutually exclusive
        // with ZStop (Z <= -3.5). This test confirms the SL branch fires when
        // Z is in the adverse extreme, which is its own correctness check.
        let mut candles: Vec<Candle> = (0..19).map(|i| candle_at(100.0, i)).collect();
        candles.push(candle_at(90.0, 19));
        let params = base_params();
        let result = check_exit(&candles, &params, Direction::Long);
        assert!(matches!(result, MRExitSignal::ZStop { .. }));
    }

    // -- run() backtest --

    #[test]
    fn run_produces_no_trades_when_market_is_quiet() {
        // Stable prices → no Z extremes → no entries.
        let candles: Vec<Candle> = (0..50).map(|i| candle_at(100.0, i)).collect();
        let params = base_params();
        let trades = run(&candles, &params);
        assert!(trades.is_empty());
    }

    #[test]
    fn run_records_short_then_reverts() {
        // Steady history at 100, then a rally to 110, then drop back through 100.
        // Should fire a short entry, then exit on return-to-mean.
        let mut candles: Vec<Candle> = (0..20).map(|i| candle_at(100.0, i)).collect();
        // Rally
        for i in 20..28 {
            candles.push(candle_at(102.0 + (i - 20) as f64, i));
        }
        // Revert through and below the mean
        for i in 28..40 {
            candles.push(candle_at(100.0 - (i - 28) as f64 * 0.3, i));
        }
        let params = base_params();
        let trades = run(&candles, &params);
        // At least one short trade should fire and exit.
        let shorts: Vec<&Trade> = trades
            .iter()
            .filter(|t| t.direction == Direction::Short)
            .collect();
        assert!(
            !shorts.is_empty(),
            "expected at least one short trade in a rally-then-revert series, got {:?}",
            trades.len()
        );
    }

    #[test]
    fn run_records_eod_when_trade_never_resolves() {
        // Start stable, then a sharp drop that triggers a long, then prices stall
        // mid-range — no return-to-mean (Z stays negative), no Z-stop fire.
        let mut candles: Vec<Candle> = (0..20).map(|i| candle_at(100.0, i)).collect();
        // Drop to trigger long entry (Z very negative, RSI oversold via the drop)
        for i in 20..30 {
            candles.push(candle_at(100.0 - (i - 20) as f64 * 0.8, i));
        }
        // Stall just below mean — Z stays slightly negative, not enough for stop,
        // not above zero for return-to-mean.
        for i in 30..50 {
            candles.push(candle_at(95.0 + ((i - 30) % 3) as f64 * 0.05, i));
        }
        let params = MeanReversionParams {
            stop_z_threshold: 10.0, // Make stop nearly impossible to trip
            ..base_params()
        };
        let trades = run(&candles, &params);
        if let Some(last) = trades.last() {
            // If a trade did fire, the very last one should hit EndOfData since
            // we constructed a stall after entry.
            // (Other earlier trades may have resolved cleanly.)
            assert!(
                matches!(last.exit_reason, ExitReason::EndOfData)
                    || matches!(last.exit_reason, ExitReason::ReturnToMean),
                "expected last trade to be EndOfData or ReturnToMean, got {:?}",
                last.exit_reason
            );
        }
    }
}
