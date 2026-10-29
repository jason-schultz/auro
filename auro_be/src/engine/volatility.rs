//! Calm or wild: the average bar range now (ATR over `period` bars) against
//! its usual level (ATR over `baseline` bars), so it works the same on any
//! instrument. `quieter` / `busier`: the recent range is below / above the
//! usual one (strict). Drawn as a percent of the price.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::indicators;
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

fn default_period() -> usize {
    14
}

fn default_baseline() -> usize {
    100
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct VolatilityParams {
    #[serde(default = "default_period")]
    pub period: usize,
    #[serde(default = "default_baseline")]
    pub baseline: usize,
}

impl VolatilityParams {
    /// (recent ATR, usual ATR), in price units.
    fn ranges(&self, candles: &[Candle]) -> Option<(f64, f64)> {
        Some((
            indicators::atr(candles, self.period)?,
            indicators::atr(candles, self.baseline)?,
        ))
    }
}

impl Signaler for VolatilityParams {
    fn warmup(&self) -> usize {
        self.period.max(self.baseline) + 1
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        let (recent, usual) = self.ranges(candles)?;
        Some(HashMap::from([
            ("quieter".to_string(), recent < usual),
            ("busier".to_string(), recent > usual),
        ]))
    }

    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        match (self.ranges(candles), candles.last()) {
            (Some((recent, usual)), Some(last)) if last.mid.close > 0.0 => HashMap::from([
                ("recent".to_string(), recent / last.mid.close * 100.0),
                ("usual".to_string(), usual / last.mid.close * 100.0),
            ]),
            _ => HashMap::new(),
        }
    }

    fn entry_reason(&self, candles: &[Candle], _direction: Direction) -> EntryReason {
        EntryReason::Indicator {
            name: "range_vs_usual",
            value: self.ranges(candles).map_or(1.0, |(r, u)| r / u),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::{Duration, TimeZone, Utc};

    /// Bars `width` wide around 100: `calm` narrow ones, then `wild` wide ones.
    fn bars(calm: usize, wild: usize) -> Vec<Candle> {
        (0..calm + wild)
            .map(|i| {
                let width = if i < calm { 0.5 } else { 4.0 };
                Candle {
                    time: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap()
                        + Duration::days(i as i64),
                    mid: OHLC {
                        open: 100.0,
                        high: 100.0 + width,
                        low: 100.0 - width,
                        close: 100.0,
                    },
                    volume: 1,
                    bid: None,
                    ask: None,
                }
            })
            .collect()
    }

    #[test]
    fn wider_bars_than_usual_are_busier() {
        let params = VolatilityParams {
            period: 3,
            baseline: 20,
        };
        let ports = params.compute(&bars(30, 5)).unwrap();
        assert!(ports["busier"] && !ports["quieter"]);
    }
}
