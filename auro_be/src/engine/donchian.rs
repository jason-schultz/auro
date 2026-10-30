use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::catalog::{port, Block, Series, Setting};
use crate::engine::indicators;
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

fn default_entry_period() -> usize {
    20
}

fn default_exit_period() -> usize {
    10
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct DonchianParams {
    #[serde(default = "default_entry_period")]
    pub entry_period: usize,
    #[serde(default = "default_exit_period")]
    pub exit_period: usize,
}

/// This block in the catalog (`engine::catalog`).
pub(crate) fn catalog() -> Block {
    Block {
        kind: "Donchian",
        key: "dc",
        name: "Breakout channel",
        watches: "The highest high and lowest low of recent bars. Breaking above that high, or below that low, is a classic breakout.",
        settings: vec![
            Setting::int(
                "entry_period",
                "Breakout over (bars)",
                20,
                "More bars mean only bigger breakouts count, so fewer trades.",
            ),
            Setting::int(
                "exit_period",
                "Exit over (bars)",
                10,
                "Fewer bars exit sooner when the move fades.",
            ),
        ],
        ports: vec![
            port("breakout_long", "the price breaks above its {entry_period:bars} high"),
            port("breakout_short", "the price breaks below its {entry_period:bars} low"),
            port("exit_long", "the price breaks below its {exit_period:bars} low"),
            port("exit_short", "the price breaks above its {exit_period:bars} high"),
        ],
        series: vec![
            Series::price("upper", "Channel high"),
            Series::price("lower", "Channel low"),
        ],
        stop: None,
    }
}

impl Signaler for DonchianParams {
    fn warmup(&self) -> usize {
        self.entry_period.max(self.exit_period) + 1
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        if self.entry_period == 0 || self.exit_period == 0 {
            return None;
        }

        let min_len = self.entry_period.max(self.exit_period) + 1;
        if candles.len() < min_len {
            return None;
        }

        let current = candles.last()?;
        let entry_channel = indicators::donchian(candles, self.entry_period)?;
        let exit_channel = indicators::donchian(candles, self.exit_period)?;

        // Strict current-bar breakout convention: must exceed prior extreme, not touch.
        let breakout_long = current.mid.high > entry_channel.upper;
        let breakout_short = current.mid.low < entry_channel.lower;
        let exit_long = current.mid.low < exit_channel.lower;
        let exit_short = current.mid.high > exit_channel.upper;

        let mut ports = HashMap::new();
        ports.insert("breakout_long".to_string(), breakout_long);
        ports.insert("breakout_short".to_string(), breakout_short);
        ports.insert("exit_long".to_string(), exit_long);
        ports.insert("exit_short".to_string(), exit_short);
        Some(ports)
    }

    /// The channels the current bar is judged against: the ones from the
    /// bars before it, as `compute` uses them.
    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        let mut values = HashMap::new();
        if let Some(entry) = indicators::donchian(candles, self.entry_period) {
            values.insert("upper".to_string(), entry.upper);
            values.insert("lower".to_string(), entry.lower);
        }
        if let Some(exit) = indicators::donchian(candles, self.exit_period) {
            values.insert("exit_upper".to_string(), exit.upper);
            values.insert("exit_lower".to_string(), exit.lower);
        }
        values
    }

    fn entry_reason(&self, candles: &[Candle], _direction: Direction) -> EntryReason {
        let channel = indicators::donchian(candles, self.entry_period).unwrap_or(
            indicators::DonchianChannel {
                upper: 0.0,
                lower: 0.0,
                mid: 0.0,
            },
        );

        EntryReason::DonchianBreakout {
            channel_high: channel.upper,
            channel_low: channel.lower,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::{Duration, TimeZone, Utc};

    fn candle(high: f64, low: f64, close: f64, idx: i64) -> Candle {
        Candle {
            time: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap() + Duration::hours(idx),
            mid: OHLC {
                open: close,
                high,
                low,
                close,
            },
            volume: 1,
            bid: None,
            ask: None,
        }
    }

    fn params() -> DonchianParams {
        DonchianParams {
            entry_period: 20,
            exit_period: 10,
        }
    }

    #[test]
    fn new_twenty_bar_high_fires_breakout_long_not_breakout_short() {
        let mut candles: Vec<Candle> = (0..20)
            .map(|i| candle(100.0 + i as f64, 80.0 + i as f64, 90.0 + i as f64, i))
            .collect();
        candles.push(candle(125.0, 110.0, 120.0, 20));

        let ports = params().compute(&candles).expect("ports should compute");
        assert!(ports["breakout_long"]);
        assert!(!ports["breakout_short"]);
    }

    #[test]
    fn new_twenty_bar_low_fires_breakout_short_not_breakout_long() {
        let mut candles: Vec<Candle> = (0..20)
            .map(|i| candle(120.0 - i as f64, 100.0 - i as f64, 110.0 - i as f64, i))
            .collect();
        candles.push(candle(90.0, 70.0, 75.0, 20));

        let ports = params().compute(&candles).expect("ports should compute");
        assert!(ports["breakout_short"]);
        assert!(!ports["breakout_long"]);
    }

    #[test]
    fn exit_long_can_fire_without_breakout_short() {
        // Prior 20 bars have an old deep low (70) outside the prior 10-bar window.
        // Current low=89 breaks prior 10-bar low=90 (exit_long) but not prior 20-bar low=70.
        let mut candles: Vec<Candle> = Vec::new();
        for i in 0..10 {
            candles.push(candle(
                100.0 + i as f64,
                70.0 + i as f64,
                90.0 + i as f64,
                i,
            ));
        }
        for i in 10..20 {
            candles.push(candle(
                95.0 + i as f64 - 10.0,
                90.0 + i as f64 - 10.0,
                92.0,
                i,
            ));
        }
        candles.push(candle(104.0, 89.0, 95.0, 20));

        let ports = params().compute(&candles).expect("ports should compute");
        assert!(ports["exit_long"]);
        assert!(!ports["breakout_short"]);
    }
}
