//! Mean reversion strategy — v1 (Investopedia baseline).
//!
//! Entry: bidirectional Z-score + RSI confirmation. Both must agree.
//!   - Long:  Z < -entry_z_threshold AND RSI < rsi_oversold
//!   - Short: Z > +entry_z_threshold AND RSI > rsi_overbought
//!
//! Exit:
//!   - Return to mean: Z crosses zero from the entry side (canonical MR exit).
//!   - Z-extension stop: Z extends further in the adverse direction past
//!     stop_z_threshold.
//!
//! Reference: Investopedia "Mean Reversion" article. Z-score formula and
//! 1.5/2.0 thresholds, RSI 30/70 confirmation, exit at the mean, SL around the
//! mean. Departures from the article (ADX gate, time stop, MTF, Hurst, etc.)
//! are deliberately deferred to v2 — see [[backlog-mr-v2]].
//!
//! Strategy logic lives entirely in the `Signaler` trait impl below. Tests
//! covering MR's composite behavior end-to-end live in `engine/strategy.rs`.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::indicators::{rsi, z_score};
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

#[derive(Debug, Deserialize, Serialize, Clone)]
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

impl Signaler for MeanReversionParams {
    fn warmup(&self) -> usize {
        self.ma_period.max(self.rsi_period + 1)
    }

    /// Emits four bool ports:
    /// - `long`:        Z < -entry_z_threshold AND RSI < rsi_oversold
    /// - `short`:       Z > +entry_z_threshold AND RSI > rsi_overbought
    /// - `exit_long`:   Z >= 0 (return-to-mean) OR Z <= -stop_z_threshold (z-stop)
    /// - `exit_short`:  Z <= 0 (return-to-mean) OR Z >= +stop_z_threshold (z-stop)
    ///
    /// # Comparator convention (freeze)
    ///
    /// Entries use **strict** comparators (`<`, `>`): equality on a threshold
    /// must not open a position. Exits use **inclusive** comparators (`<=`,
    /// `>=`): a mean-cross at exact equality must not be missed. The asymmetry
    /// is intentional ("hard to enter, easy to exit") and load-bearing for
    /// parameter sweeps — do not "normalize" it.
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
