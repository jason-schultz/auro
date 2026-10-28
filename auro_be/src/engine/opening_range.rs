//! Opening-range breakout: the high and low of the first `minutes` of the US
//! session (from 09:30 New York). Once that range is set, `breakout_long` /
//! `breakout_short`: the close is above its high / below its low (strict);
//! `inside`: neither. `session_close`: the bar closes at or after the session
//! close (or before the open), so a day trade can always exit. Intraday bars
//! only.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::indicators::{self, OpeningRange};
use crate::engine::session::{self, BarClock};
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

fn default_minutes() -> i64 {
    30
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct OpeningRangeParams {
    #[serde(default = "default_minutes")]
    pub minutes: i64,
}

impl OpeningRangeParams {
    /// The range, once today's session has run past it.
    fn range(&self, candles: &[Candle], clock: &BarClock) -> Option<OpeningRange> {
        let bars = (self.minutes / clock.bar_minutes).max(1) as usize;
        let today = session::today(candles);
        (today.len() > bars)
            .then(|| indicators::opening_range(today, bars))
            .flatten()
    }
}

impl Signaler for OpeningRangeParams {
    fn warmup(&self) -> usize {
        2
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        let clock = BarClock::of(candles)?;
        let close = candles.last()?.mid.close;
        let (long, short, inside) = match self.range(candles, &clock) {
            Some(r) => (
                close > r.high,
                close < r.low,
                close <= r.high && close >= r.low,
            ),
            None => (false, false, false),
        };
        Some(HashMap::from([
            ("breakout_long".to_string(), long),
            ("breakout_short".to_string(), short),
            ("inside".to_string(), inside),
            ("session_close".to_string(), clock.is_session_close()),
        ]))
    }

    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        BarClock::of(candles)
            .and_then(|clock| self.range(candles, &clock))
            .map(|r| HashMap::from([("high".to_string(), r.high), ("low".to_string(), r.low)]))
            .unwrap_or_default()
    }

    fn entry_reason(&self, candles: &[Candle], direction: Direction) -> EntryReason {
        let range = BarClock::of(candles).and_then(|clock| self.range(candles, &clock));
        EntryReason::Indicator {
            name: "opening_range_edge",
            value: range.map_or(0.0, |r| match direction {
                Direction::Long => r.high,
                Direction::Short => r.low,
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::{DateTime, Duration, TimeZone, Utc};

    fn bar(time: DateTime<Utc>, high: f64, low: f64, close: f64) -> Candle {
        Candle {
            time,
            mid: OHLC {
                open: close,
                high,
                low,
                close,
            },
            volume: 10,
            bid: None,
            ask: None,
        }
    }

    /// Six M5 bars from 09:30 New York (14:30 UTC on Monday 2026-01-05).
    fn morning(last_close: f64) -> Vec<Candle> {
        let open = Utc.with_ymd_and_hms(2026, 1, 5, 14, 30, 0).unwrap();
        let mut candles: Vec<Candle> = (0..6)
            .map(|i| bar(open + Duration::minutes(5 * i), 101.0, 99.0, 100.0))
            .collect();
        candles.push(bar(
            open + Duration::minutes(30),
            last_close,
            last_close,
            last_close,
        ));
        candles
    }

    #[test]
    fn closing_above_the_first_half_hour_is_a_breakout() {
        let ports = OpeningRangeParams { minutes: 30 }
            .compute(&morning(102.0))
            .unwrap();
        assert!(ports["breakout_long"] && !ports["breakout_short"] && !ports["inside"]);
    }

    #[test]
    fn nothing_breaks_out_before_the_range_is_set() {
        let candles = morning(102.0);
        let ports = OpeningRangeParams { minutes: 30 }
            .compute(&candles[..3])
            .unwrap();
        assert!(!ports["breakout_long"] && !ports["inside"]);
    }
}
