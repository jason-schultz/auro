//! Today's volume-weighted average price, anchored at the US open (09:30 New
//! York): the average price everyone has paid so far today. `above` /
//! `below`: the close against it (strict). Intraday bars only; outside the
//! regular session, and on daily bars, both are false. Volume is OANDA tick
//! volume for CFDs.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::indicators;
use crate::engine::session;
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct VwapParams {}

fn session_vwap(candles: &[Candle]) -> Option<f64> {
    indicators::vwap(session::today(candles))
}

impl Signaler for VwapParams {
    fn warmup(&self) -> usize {
        2
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        let close = candles.last()?.mid.close;
        let (above, below) =
            session_vwap(candles).map_or((false, false), |v| (close > v, close < v));
        Some(HashMap::from([
            ("above".to_string(), above),
            ("below".to_string(), below),
        ]))
    }

    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        session_vwap(candles)
            .map(|v| HashMap::from([("vwap".to_string(), v)]))
            .unwrap_or_default()
    }

    fn entry_reason(&self, candles: &[Candle], _direction: Direction) -> EntryReason {
        EntryReason::Indicator {
            name: "vwap",
            value: session_vwap(candles).unwrap_or(0.0),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::{DateTime, Duration, TimeZone, Utc};

    /// 2026-01-05 is a Monday in EST: 09:30 New York = 14:30 UTC.
    fn bar(time: DateTime<Utc>, close: f64) -> Candle {
        Candle {
            time,
            mid: OHLC {
                open: close,
                high: close,
                low: close,
                close,
            },
            volume: 10,
            bid: None,
            ask: None,
        }
    }

    #[test]
    fn the_average_starts_at_the_open_and_the_close_is_judged_against_it() {
        let open = Utc.with_ymd_and_hms(2026, 1, 5, 14, 30, 0).unwrap();
        let candles = vec![
            bar(open - Duration::minutes(30), 50.0), // pre-market, left out
            bar(open, 100.0),
            bar(open + Duration::minutes(5), 102.0),
            bar(open + Duration::minutes(10), 104.0),
        ];
        assert_eq!(VwapParams {}.series(&candles)["vwap"], 102.0);
        assert!(VwapParams {}.compute(&candles).unwrap()["above"]);
    }
}
