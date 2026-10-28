//! Trend strength (Wilder's ADX over `period` bars, 0 to 100, direction-
//! blind). `trending`: ADX at or above `threshold` (25 is the textbook line
//! for a real trend); `ranging`: below it. A filter, not an entry signal:
//! combine it with a block that says which way.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::indicators;
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

fn default_period() -> usize {
    14
}

fn default_threshold() -> f64 {
    25.0
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AdxFilterParams {
    #[serde(default = "default_period")]
    pub period: usize,
    #[serde(default = "default_threshold")]
    pub threshold: f64,
}

impl Signaler for AdxFilterParams {
    fn warmup(&self) -> usize {
        self.period * 2 + 1
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        let adx = indicators::adx(candles, self.period)?;
        Some(HashMap::from([
            ("trending".to_string(), adx >= self.threshold),
            ("ranging".to_string(), adx < self.threshold),
        ]))
    }

    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        indicators::adx(candles, self.period)
            .map(|adx| HashMap::from([("adx".to_string(), adx)]))
            .unwrap_or_default()
    }

    fn entry_reason(&self, candles: &[Candle], _direction: Direction) -> EntryReason {
        EntryReason::Indicator {
            name: "adx",
            value: indicators::adx(candles, self.period).unwrap_or(0.0),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::test_candles::daily as candles;

    #[test]
    fn a_steady_climb_is_trending() {
        let closes: Vec<f64> = (0..40).map(|i| 100.0 + i as f64).collect();
        let params = AdxFilterParams {
            period: 5,
            threshold: 25.0,
        };
        let ports = params.compute(&candles(&closes)).unwrap();
        assert!(ports["trending"] && !ports["ranging"]);
        assert!(params.series(&candles(&closes))["adx"] >= 25.0);
    }
}
