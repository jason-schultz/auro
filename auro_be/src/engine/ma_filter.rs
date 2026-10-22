use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::indicators::{self, MaType};
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct MaFilterParams {
    pub period: usize,
    #[serde(default)]
    pub ma_type: MaType,
}

impl Signaler for MaFilterParams {
    fn warmup(&self) -> usize {
        self.period
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        let close = candles.last()?.mid.close;
        let ma = indicators::moving_average(candles, self.period, self.ma_type)?;

        let mut ports = HashMap::new();
        ports.insert("above".to_string(), close > ma);
        ports.insert("below".to_string(), close < ma);
        Some(ports)
    }

    fn entry_reason(&self, candles: &[Candle], direction: Direction) -> EntryReason {
        let close = candles.last().map(|c| c.mid.close).unwrap_or(0.0);
        let ma = indicators::moving_average(candles, self.period, self.ma_type).unwrap_or(0.0);

        match direction {
            Direction::Long => EntryReason::CrossAbove {
                fast_ma: close,
                slow_ma: ma,
            },
            Direction::Short => EntryReason::CrossBelow {
                fast_ma: close,
                slow_ma: ma,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::{Duration, TimeZone, Utc};

    fn candle(close: f64, idx: i64) -> Candle {
        Candle {
            time: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap() + Duration::days(idx),
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

    #[test]
    fn emits_above_and_below_ports() {
        let candles = vec![candle(100.0, 0), candle(101.0, 1), candle(102.0, 2)];
        let params = MaFilterParams {
            period: 3,
            ma_type: MaType::Sma,
        };
        let ports = params.compute(&candles).expect("ports should compute");

        assert!(ports["above"]);
        assert!(!ports["below"]);
    }

    #[test]
    fn returns_none_when_not_enough_candles() {
        let candles = vec![candle(100.0, 0), candle(101.0, 1)];
        let params = MaFilterParams {
            period: 3,
            ma_type: MaType::Sma,
        };
        assert!(params.compute(&candles).is_none());
    }
}
