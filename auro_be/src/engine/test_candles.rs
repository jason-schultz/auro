//! Candles for tests: one flat bar per close (open = high = low = close),
//! one day apart from 2026-01-01.

use chrono::{Duration, TimeZone, Utc};

use crate::engine::types::{Candle, OHLC};

pub(crate) fn daily(closes: &[f64]) -> Vec<Candle> {
    closes
        .iter()
        .enumerate()
        .map(|(i, &c)| Candle {
            time: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap() + Duration::days(i as i64),
            mid: OHLC {
                open: c,
                high: c,
                low: c,
                close: c,
            },
            volume: 1,
            bid: None,
            ask: None,
        })
        .collect()
}
