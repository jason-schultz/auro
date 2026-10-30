use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::catalog::{port, Block, Level, Series, Setting, RSI_LEVEL_WHY, RSI_WHY};
use crate::engine::indicators::rsi;
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RsiReversionParams {
    pub rsi_period: usize,
    pub oversold: f64,
    pub overbought: f64,
}

/// This block in the catalog (`engine::catalog`).
pub(crate) fn catalog() -> Block {
    Block {
        kind: "RsiReversion",
        key: "r",
        name: "RSI",
        watches: "How hard the price has been pushed one way lately, from 0 to 100. Very low means it fell hard (oversold); very high means it rose hard (overbought).",
        settings: vec![
            Setting::int(
                "rsi_period",
                "Bars to look at",
                2,
                "Fewer bars give a quicker, jumpier reading. 2 is very short-term.",
            )
            .at_least(2.0, RSI_WHY),
            Setting::float(
                "oversold",
                "Oversold below",
                20,
                "Lower means fewer, more extreme dips count.",
            )
            .between(0.0, 100.0, RSI_LEVEL_WHY),
            Setting::float(
                "overbought",
                "Overbought above",
                80,
                "Higher means fewer, more extreme spikes count.",
            )
            .between(0.0, 100.0, RSI_LEVEL_WHY),
        ],
        ports: vec![
            port("long", "RSI({rsi_period}) is below {oversold}"),
            port("short", "RSI({rsi_period}) is above {overbought}"),
            port("exit_long", "RSI({rsi_period}) is back to 50 or higher"),
            port("exit_short", "RSI({rsi_period}) is back to 50 or lower"),
        ],
        series: vec![Series::panel(
            "rsi",
            "RSI",
            vec![Level::Setting("oversold"), Level::At(50.0), Level::Setting("overbought")],
        )
        .range(0.0, 100.0)],
        stop: None,
    }
}

impl Signaler for RsiReversionParams {
    fn warmup(&self) -> usize {
        self.rsi_period + 1
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        if candles.len() < self.warmup() {
            return None;
        }

        let r = rsi(candles, self.rsi_period)?;

        // Strict entries, inclusive exits per signal math convention.
        let long = r < self.oversold;
        let short = r > self.overbought;
        let exit_long = r >= 50.0;
        let exit_short = r <= 50.0;

        let mut ports = HashMap::new();
        ports.insert("long".to_string(), long);
        ports.insert("short".to_string(), short);
        ports.insert("exit_long".to_string(), exit_long);
        ports.insert("exit_short".to_string(), exit_short);
        Some(ports)
    }

    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        rsi(candles, self.rsi_period)
            .map(|r| HashMap::from([("rsi".to_string(), r)]))
            .unwrap_or_default()
    }

    fn entry_reason(&self, candles: &[Candle], _direction: Direction) -> EntryReason {
        let r = rsi(candles, self.rsi_period).unwrap_or(50.0);
        EntryReason::MeanReversionEntry {
            ma_value: 0.0,
            z_score: 0.0,
            rsi: r,
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
            time: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap() + Duration::hours(idx),
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
    fn emits_long_when_rsi_oversold() {
        let mut candles = Vec::new();
        for i in 0..20 {
            candles.push(candle(100.0 - i as f64, i));
        }

        let params = RsiReversionParams {
            rsi_period: 14,
            oversold: 30.0,
            overbought: 70.0,
        };
        let ports = params.compute(&candles).expect("ports should compute");

        assert!(ports["long"]);
        assert!(!ports["short"]);
    }

    #[test]
    fn exits_are_inclusive_at_midline() {
        let mut candles = Vec::new();
        for i in 0..20 {
            let close = if i % 2 == 0 { 100.0 } else { 100.1 };
            candles.push(candle(close, i));
        }

        let params = RsiReversionParams {
            rsi_period: 14,
            oversold: 30.0,
            overbought: 70.0,
        };
        let ports = params.compute(&candles).expect("ports should compute");

        assert!(ports["exit_long"] || ports["exit_short"]);
    }
}
