//! Trend strength (Wilder's ADX over `period` bars, 0 to 100, direction-
//! blind). `trending`: ADX at or above `threshold` (25 is the textbook line
//! for a real trend); `ranging`: below it. A filter, not an entry signal:
//! combine it with a block that says which way.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::catalog::{port, Block, Level, Series, Setting};
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

/// This block in the catalog (`engine::catalog`).
pub(crate) fn catalog() -> Block {
    Block {
        kind: "AdxFilter",
        key: "adx",
        name: "Trend strength (ADX)",
        watches: "How strong the current trend is, from 0 to 100, whichever way it points. Above about 25 is a real trend; below it the price is mostly drifting sideways. Use it with a block that says which way.",
        settings: vec![
            Setting::int(
                "period",
                "Bars",
                14,
                "Fewer bars react sooner but jump around more.",
            )
            .at_least(2.0, "an ADX over fewer than 2 bars is only ever 0 or 100"),
            Setting::float(
                "threshold",
                "Strong trend at",
                25,
                "Higher means only the strongest trends count.",
            )
            .between(0.0, 100.0, "an ADX only reads between 0 and 100"),
        ],
        ports: vec![
            port("trending", "there's a strong trend (ADX at {threshold} or more)"),
            port("ranging", "there's no strong trend (ADX below {threshold})"),
        ],
        series: vec![Series::panel(
            "adx",
            "Trend strength (ADX)",
            vec![Level::Setting("threshold")],
        )],
        stop: None,
    }
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
