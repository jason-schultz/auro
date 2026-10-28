//! Classic floor-trader pivot points from the previous session's high, low
//! and close (the previous bar's on daily bars): the pivot, the first
//! resistance R1 above it and the first support S1 below it. `above_pivot` /
//! `below_pivot`, `above_r1`, `below_s1`: the close against them (strict).

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::indicators::{self, PivotPoints};
use crate::engine::session;
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct PivotPointsParams {}

fn pivots(candles: &[Candle]) -> Option<PivotPoints> {
    let (high, low, close) = session::previous_session(candles)?;
    Some(indicators::pivot_points(high, low, close))
}

impl Signaler for PivotPointsParams {
    fn warmup(&self) -> usize {
        2
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        let p = pivots(candles)?;
        let close = candles.last()?.mid.close;
        Some(HashMap::from([
            ("above_pivot".to_string(), close > p.pp),
            ("below_pivot".to_string(), close < p.pp),
            ("above_r1".to_string(), close > p.r1),
            ("below_s1".to_string(), close < p.s1),
        ]))
    }

    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        pivots(candles)
            .map(|p| {
                HashMap::from([
                    ("pivot".to_string(), p.pp),
                    ("r1".to_string(), p.r1),
                    ("s1".to_string(), p.s1),
                ])
            })
            .unwrap_or_default()
    }

    fn entry_reason(&self, candles: &[Candle], _direction: Direction) -> EntryReason {
        EntryReason::Indicator {
            name: "pivot",
            value: pivots(candles).map_or(0.0, |p| p.pp),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::{Duration, TimeZone, Utc};

    #[test]
    fn daily_pivots_come_from_the_previous_bar() {
        let day = |i: i64, high: f64, low: f64, close: f64| Candle {
            time: Utc.with_ymd_and_hms(2026, 1, 5, 21, 0, 0).unwrap() + Duration::days(i),
            mid: OHLC {
                open: close,
                high,
                low,
                close,
            },
            volume: 1,
            bid: None,
            ask: None,
        };
        // Pivot = (110 + 90 + 100) / 3 = 100; R1 = 110; S1 = 90.
        let candles = vec![day(0, 110.0, 90.0, 100.0), day(1, 112.0, 108.0, 111.0)];

        let series = PivotPointsParams {}.series(&candles);
        assert_eq!(
            (series["pivot"], series["r1"], series["s1"]),
            (100.0, 110.0, 90.0)
        );

        let ports = PivotPointsParams {}.compute(&candles).unwrap();
        assert!(ports["above_pivot"] && ports["above_r1"] && !ports["below_s1"]);
    }
}
