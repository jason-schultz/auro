//! Trend following strategy — v1 (textbook Dual MA Crossover).
//!
//! Entry: bidirectional MA crossover.
//!   - Long:  fast SMA crosses above slow SMA (bullish cross)
//!   - Short: fast SMA crosses below slow SMA (bearish cross)
//!
//! Exit: opposite crossover. Long position exits on bearish cross;
//! short position exits on bullish cross.
//!
//! Stop loss: fixed percentage (configured at top-level Strategy, not here).
//!
//! Reference: Britannica "Trend Following" — 50/200 SMA golden/death cross
//! (Wall Street standard). Also financestrategists.com "Dual Moving Average
//! Crossover" strategy. Departures from textbook (ADX gate, trailing stops,
//! breakeven transitions, confirm bars, take profit) are deferred to v2 or
//! to composite-layer enhancements per
//! [[feedback-textbook-baselines-then-composites]].
//!
//! Exposes `compute_ports` for the new composite strategy shape — see
//! [[decision-canonical-strategy-shape]].

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::indicators;
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum MaType {
    Sma,
    Ema,
}

fn default_ma_type() -> MaType {
    MaType::Sma
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TrendFollowingParams {
    /// Fast moving-average period. Default 50 (Britannica golden cross).
    pub fast_period: usize,
    /// Slow moving-average period. Default 200 (Britannica golden cross).
    pub slow_period: usize,
    /// Moving-average type. Defaults to SMA for backward compatibility.
    #[serde(default = "default_ma_type")]
    pub ma_type: MaType,
}

/// Compute output ports for the TrendFollowing component at the current bar.
/// Returns:
///   - `bullish_cross`: true on the bar where fast SMA crosses above slow SMA
///   - `bearish_cross`: true on the bar where fast SMA crosses below slow SMA
///
/// Returns None if fewer than `slow_period + 1` candles are available.
pub fn compute_ports(
    candles: &[Candle],
    params: &TrendFollowingParams,
) -> Option<HashMap<String, bool>> {
    if params.fast_period == 0
        || params.slow_period == 0
        || params.fast_period >= params.slow_period
    {
        return None;
    }
    if candles.len() < params.slow_period + 1 {
        return None;
    }

    let n = candles.len();
    let fast = ma_value(candles, n, params.fast_period, params.ma_type);
    let slow = ma_value(candles, n, params.slow_period, params.ma_type);
    let prev_fast = ma_value(candles, n - 1, params.fast_period, params.ma_type);
    let prev_slow = ma_value(candles, n - 1, params.slow_period, params.ma_type);

    // Cross detection convention (freeze): inclusive on the prior bar
    // (`<=`/`>=`), strict on the current bar (`>`/`<`). Required so a flat
    // touch on the previous bar followed by separation still counts as a
    // cross — using strict on both sides would silently miss equal-touch
    // crossovers.
    let bullish_cross = prev_fast <= prev_slow && fast > slow;
    let bearish_cross = prev_fast >= prev_slow && fast < slow;

    let mut ports = HashMap::new();
    ports.insert("bullish_cross".to_string(), bullish_cross);
    ports.insert("bearish_cross".to_string(), bearish_cross);
    Some(ports)
}

fn sma(candles: &[Candle], end_exclusive: usize, period: usize) -> f64 {
    let slice = &candles[end_exclusive - period..end_exclusive];
    slice.iter().map(|c| c.mid.close).sum::<f64>() / period as f64
}

fn ma_value(candles: &[Candle], end_exclusive: usize, period: usize, ma_type: MaType) -> f64 {
    match ma_type {
        MaType::Sma => sma(candles, end_exclusive, period),
        MaType::Ema => indicators::ema(&candles[..end_exclusive], period)
            .expect("EMA preconditions satisfied by caller"),
    }
}

impl Signaler for TrendFollowingParams {
    fn warmup(&self) -> usize {
        self.slow_period + 1
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        compute_ports(candles, self)
    }

    fn entry_reason(&self, candles: &[Candle], direction: Direction) -> EntryReason {
        let n = candles.len();
        let fast = ma_value(candles, n, self.fast_period, self.ma_type);
        let slow = ma_value(candles, n, self.slow_period, self.ma_type);
        match direction {
            Direction::Long => EntryReason::CrossAbove {
                fast_ma: fast,
                slow_ma: slow,
            },
            Direction::Short => EntryReason::CrossBelow {
                fast_ma: fast,
                slow_ma: slow,
            },
        }
    }

    // TF uses fixed-pct stop at the top level; no component-driven stop distance.
    // (stop_distance falls through to the trait's default `None`.)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::{Duration, TimeZone, Utc};

    fn make_candle(close: f64, idx: i64) -> Candle {
        Candle {
            time: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap() + Duration::hours(idx),
            mid: OHLC {
                open: close,
                high: close,
                low: close,
                close,
            },
            volume: 1,
            bid: None,
            ask: None,
        }
    }

    fn params(fast: usize, slow: usize) -> TrendFollowingParams {
        TrendFollowingParams {
            fast_period: fast,
            slow_period: slow,
            ma_type: MaType::Sma,
        }
    }

    fn params_with_type(fast: usize, slow: usize, ma_type: MaType) -> TrendFollowingParams {
        TrendFollowingParams {
            fast_period: fast,
            slow_period: slow,
            ma_type,
        }
    }

    #[test]
    fn returns_none_with_insufficient_candles() {
        let candles: Vec<Candle> = (0..50).map(|i| make_candle(100.0, i)).collect();
        assert!(compute_ports(&candles, &params(10, 200)).is_none());
    }

    #[test]
    fn returns_none_when_fast_geq_slow() {
        let candles: Vec<Candle> = (0..250).map(|i| make_candle(100.0, i)).collect();
        assert!(compute_ports(&candles, &params(50, 50)).is_none());
        assert!(compute_ports(&candles, &params(200, 50)).is_none());
    }

    #[test]
    fn flat_prices_produce_no_cross() {
        let candles: Vec<Candle> = (0..250).map(|i| make_candle(100.0, i)).collect();
        let ports = compute_ports(&candles, &params(50, 200)).unwrap();
        assert!(!ports["bullish_cross"]);
        assert!(!ports["bearish_cross"]);
    }

    #[test]
    fn bullish_cross_fires_on_upward_acceleration() {
        // Build a series where price has been below the slow MA, then rises
        // enough that the fast MA crosses above the slow MA on the final bar.
        // Use small periods so we can construct deterministic data.
        let mut prices = vec![100.0; 30]; // baseline flat
                                          // Step down then sharply up, so fast catches up to slow on the last bar.
        for i in 0..15 {
            prices.push(95.0 + i as f64); // rises from 95 to 109
        }
        let candles: Vec<Candle> = prices
            .into_iter()
            .enumerate()
            .map(|(i, p)| make_candle(p, i as i64))
            .collect();
        // Use periods small enough that the crossover lands at the end.
        // Verify a cross-up occurs somewhere in the series; we check the
        // final bar position can be made to fire by adjusting periods.
        // For a robust test, iterate over all positions and confirm at
        // least one bullish cross exists in the series.
        let mut found_bullish = false;
        for i in 11..candles.len() {
            let window = &candles[..=i];
            if let Some(ports) = compute_ports(window, &params(3, 10)) {
                if ports["bullish_cross"] {
                    found_bullish = true;
                    break;
                }
            }
        }
        assert!(
            found_bullish,
            "expected at least one bullish cross in an upward-accelerating series"
        );
    }

    #[test]
    fn bearish_cross_fires_on_downward_acceleration() {
        let mut prices = vec![100.0; 30];
        for i in 0..15 {
            prices.push(105.0 - i as f64);
        }
        let candles: Vec<Candle> = prices
            .into_iter()
            .enumerate()
            .map(|(i, p)| make_candle(p, i as i64))
            .collect();
        let mut found_bearish = false;
        for i in 11..candles.len() {
            let window = &candles[..=i];
            if let Some(ports) = compute_ports(window, &params(3, 10)) {
                if ports["bearish_cross"] {
                    found_bearish = true;
                    break;
                }
            }
        }
        assert!(
            found_bearish,
            "expected at least one bearish cross in a downward-accelerating series"
        );
    }

    #[test]
    fn bullish_and_bearish_cannot_both_fire_same_bar() {
        // Construction: a crossover by definition is one-directional in a single
        // bar. Verify by iterating over many bars on a random walk-ish series.
        let prices: Vec<f64> = (0..500)
            .map(|i| 100.0 + (i as f64 * 0.13).sin() * 5.0)
            .collect();
        let candles: Vec<Candle> = prices
            .into_iter()
            .enumerate()
            .map(|(i, p)| make_candle(p, i as i64))
            .collect();
        for i in 11..candles.len() {
            let window = &candles[..=i];
            if let Some(ports) = compute_ports(window, &params(3, 10)) {
                assert!(
                    !(ports["bullish_cross"] && ports["bearish_cross"]),
                    "both cross signals fired on the same bar — impossible"
                );
            }
        }
    }

    #[test]
    fn ema_bullish_cross_fires_on_upward_acceleration() {
        let mut prices = vec![100.0; 30];
        for i in 0..15 {
            prices.push(95.0 + i as f64);
        }

        let candles: Vec<Candle> = prices
            .into_iter()
            .enumerate()
            .map(|(i, p)| make_candle(p, i as i64))
            .collect();

        let mut found_bullish = false;
        for i in 11..candles.len() {
            let window = &candles[..=i];
            if let Some(ports) = compute_ports(window, &params_with_type(3, 10, MaType::Ema)) {
                if ports["bullish_cross"] {
                    found_bullish = true;
                    break;
                }
            }
        }

        assert!(
            found_bullish,
            "expected at least one EMA bullish cross in an upward-accelerating series"
        );
    }

    #[test]
    fn params_json_without_ma_type_defaults_to_sma() {
        let params: TrendFollowingParams =
            serde_json::from_value(serde_json::json!({ "fast_period": 50, "slow_period": 200 }))
                .expect("trend-following params should parse");

        assert_eq!(params.ma_type, MaType::Sma);
    }
}
