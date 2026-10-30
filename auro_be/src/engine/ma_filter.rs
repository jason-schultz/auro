use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::catalog::{ma_type, port, Block, Series, Setting, AVERAGE_WHY};
use crate::engine::indicators::{self, MaType};
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct MaFilterParams {
    pub period: usize,
    #[serde(default)]
    pub ma_type: MaType,
}

/// This block in the catalog (`engine::catalog`).
pub(crate) fn catalog() -> Block {
    Block {
        kind: "MaFilter",
        key: "t",
        name: "Moving average",
        watches: "The average price over a number of bars. Price above it usually means an uptrend; below it, a downtrend.",
        settings: vec![
            Setting::int(
                "period",
                "Bars",
                100,
                "More bars make a slower, smoother line that only shows the big trend.",
            )
            .at_least(2.0, AVERAGE_WHY),
            ma_type(),
        ],
        ports: vec![
            port("above", "the price is above its {ma_type} average over {period:bars}"),
            port("below", "the price is below its {ma_type} average over {period:bars}"),
        ],
        series: vec![Series::price("ma", "Average")],
        stop: None,
    }
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

    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        indicators::moving_average(candles, self.period, self.ma_type)
            .map(|ma| HashMap::from([("ma".to_string(), ma)]))
            .unwrap_or_default()
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

    #[test]
    fn series_reports_the_average_to_draw() {
        let params = MaFilterParams {
            period: 3,
            ma_type: MaType::Sma,
        };
        let candles = vec![
            candle(1.0, 0),
            candle(2.0, 1),
            candle(3.0, 2),
            candle(4.0, 3),
        ];

        assert_eq!(params.series(&candles)["ma"], 3.0);
        assert!(params.series(&candles[..2]).is_empty());
    }
}
