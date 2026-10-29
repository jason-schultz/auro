//! Bollinger bands (Bollinger's original: a `period`-bar simple average with
//! a band `std_dev_mult` population standard deviations either side, 20 and
//! 2 by default). `below_band` / `above_band`: the close is outside the band.
//! `above_middle` / `below_middle`: the close against the average, inclusive
//! (the usual "back to normal" exit, per the MR inclusive-exit convention).

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::indicators;
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

fn default_period() -> usize {
    20
}

fn default_std_dev_mult() -> f64 {
    2.0
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct BollingerParams {
    #[serde(default = "default_period")]
    pub period: usize,
    #[serde(default = "default_std_dev_mult")]
    pub std_dev_mult: f64,
}

impl Signaler for BollingerParams {
    fn warmup(&self) -> usize {
        self.period
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        let b = indicators::bollinger(candles, self.period, self.std_dev_mult)?;
        let close = candles.last()?.mid.close;
        Some(HashMap::from([
            ("below_band".to_string(), close < b.lower),
            ("above_band".to_string(), close > b.upper),
            ("above_middle".to_string(), close >= b.middle),
            ("below_middle".to_string(), close <= b.middle),
        ]))
    }

    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        indicators::bollinger(candles, self.period, self.std_dev_mult)
            .map(|b| {
                HashMap::from([
                    ("upper".to_string(), b.upper),
                    ("middle".to_string(), b.middle),
                    ("lower".to_string(), b.lower),
                ])
            })
            .unwrap_or_default()
    }

    fn entry_reason(&self, candles: &[Candle], _direction: Direction) -> EntryReason {
        EntryReason::Indicator {
            name: "bollinger_position",
            value: indicators::bollinger(candles, self.period, self.std_dev_mult)
                .map_or(0.5, |b| b.position),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::test_candles::daily as candles;

    fn params() -> BollingerParams {
        BollingerParams {
            period: 4,
            std_dev_mult: 1.0,
        }
    }

    #[test]
    fn a_close_far_below_the_average_is_below_the_band() {
        let ports = params()
            .compute(&candles(&[100.0, 101.0, 100.0, 90.0]))
            .unwrap();
        assert!(ports["below_band"] && ports["below_middle"]);
        assert!(!ports["above_band"] && !ports["above_middle"]);
    }

    #[test]
    fn series_reports_the_band_to_draw() {
        let series = params().series(&candles(&[100.0, 100.0, 100.0, 100.0]));
        assert_eq!(series["middle"], 100.0);
        assert_eq!(series["upper"], 100.0);
    }
}
