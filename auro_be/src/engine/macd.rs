use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::catalog::{port, Block, Level, Series, Setting, AVERAGE_WHY, SIGNAL_LINE_WHY};
use crate::engine::indicators;
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

fn default_fast() -> usize {
    12
}

fn default_slow() -> usize {
    26
}

fn default_signal() -> usize {
    9
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct MacdParams {
    #[serde(default = "default_fast")]
    pub fast_period: usize,
    #[serde(default = "default_slow")]
    pub slow_period: usize,
    #[serde(default = "default_signal")]
    pub signal_period: usize,
}

/// This block in the catalog (`engine::catalog`).
pub(crate) fn catalog() -> Block {
    Block {
        kind: "Macd",
        key: "m",
        name: "MACD",
        watches: "The gap between a fast and a slow average (MACD), and a smoothed copy of it (the signal line). MACD crossing above its signal line means momentum is turning up.",
        settings: vec![
            Setting::int("fast_period", "Fast", 12, "Bars for the fast average."),
            Setting::int("slow_period", "Slow", 26, "Bars for the slow average.")
                .at_least(2.0, AVERAGE_WHY),
            Setting::int(
                "signal_period",
                "Signal",
                9,
                "Bars to smooth MACD into its signal line. Fewer reacts sooner.",
            )
            .at_least(2.0, SIGNAL_LINE_WHY),
        ],
        ports: vec![
            port("bullish", "MACD is above its signal line"),
            port("bearish", "MACD is below its signal line"),
            port("bullish_cross", "MACD crosses above its signal line"),
            port("bearish_cross", "MACD crosses below its signal line"),
        ],
        series: vec![Series::panel("macd", "MACD", vec![Level::At(0.0)]).with("signal")],
        stop: None,
    }
}

impl Signaler for MacdParams {
    fn warmup(&self) -> usize {
        // EMA window seeding needs enough bars to build slow EMA and then
        // smooth the MACD line by `signal_period`.
        self.slow_period + self.signal_period
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        if self.fast_period == 0
            || self.slow_period == 0
            || self.signal_period == 0
            || self.fast_period >= self.slow_period
        {
            return None;
        }

        // We need MACD at n and n-1 to detect cross events.
        let min_len = self.slow_period + self.signal_period + 1;
        if candles.len() < min_len {
            return None;
        }

        let n = candles.len();
        let curr = indicators::macd(
            candles,
            self.fast_period,
            self.slow_period,
            self.signal_period,
        )?;
        let prev = indicators::macd(
            &candles[..n - 1],
            self.fast_period,
            self.slow_period,
            self.signal_period,
        )?;

        // Cross detection convention (freeze): inclusive prior bar, strict current bar.
        let bullish_cross = prev.macd_line <= prev.signal_line && curr.macd_line > curr.signal_line;
        let bearish_cross = prev.macd_line >= prev.signal_line && curr.macd_line < curr.signal_line;
        let bullish = curr.histogram > 0.0;
        let bearish = curr.histogram < 0.0;

        let mut ports = HashMap::new();
        ports.insert("bullish_cross".to_string(), bullish_cross);
        ports.insert("bearish_cross".to_string(), bearish_cross);
        ports.insert("bullish".to_string(), bullish);
        ports.insert("bearish".to_string(), bearish);
        Some(ports)
    }

    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        indicators::macd(
            candles,
            self.fast_period,
            self.slow_period,
            self.signal_period,
        )
        .map(|m| {
            HashMap::from([
                ("macd".to_string(), m.macd_line),
                ("signal".to_string(), m.signal_line),
            ])
        })
        .unwrap_or_default()
    }

    fn entry_reason(&self, candles: &[Candle], _direction: Direction) -> EntryReason {
        let out = indicators::macd(
            candles,
            self.fast_period,
            self.slow_period,
            self.signal_period,
        )
        .unwrap_or(indicators::MacdOutput {
            macd_line: 0.0,
            signal_line: 0.0,
            histogram: 0.0,
        });

        EntryReason::MacdCross {
            macd: out.macd_line,
            signal: out.signal_line,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::{Duration, TimeZone, Utc};

    fn make_candle(close: f64, idx: i64) -> Candle {
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

    fn params() -> MacdParams {
        MacdParams {
            fast_period: 3,
            slow_period: 6,
            signal_period: 3,
        }
    }

    #[test]
    fn bullish_cross_sets_trigger_and_filter_ports() {
        let mut prices = vec![100.0; 30];
        for i in 0..20 {
            prices.push(95.0 + i as f64);
        }
        let candles: Vec<Candle> = prices
            .into_iter()
            .enumerate()
            .map(|(i, p)| make_candle(p, i as i64))
            .collect();

        let p = params();
        let mut found = false;
        for i in (p.warmup() + 1)..candles.len() {
            let window = &candles[..=i];
            if let Some(ports) = p.compute(window) {
                if ports["bullish_cross"] {
                    assert!(ports["bullish"]);
                    assert!(!ports["bearish_cross"]);
                    assert!(!ports["bearish"]);
                    found = true;
                    break;
                }
            }
        }

        assert!(found, "expected a bullish MACD cross");
    }

    #[test]
    fn bearish_cross_sets_trigger_and_filter_ports() {
        let mut prices = vec![100.0; 30];
        for i in 0..20 {
            prices.push(105.0 - i as f64);
        }
        let candles: Vec<Candle> = prices
            .into_iter()
            .enumerate()
            .map(|(i, p)| make_candle(p, i as i64))
            .collect();

        let p = params();
        let mut found = false;
        for i in (p.warmup() + 1)..candles.len() {
            let window = &candles[..=i];
            if let Some(ports) = p.compute(window) {
                if ports["bearish_cross"] {
                    assert!(ports["bearish"]);
                    assert!(!ports["bullish_cross"]);
                    assert!(!ports["bullish"]);
                    found = true;
                    break;
                }
            }
        }

        assert!(found, "expected a bearish MACD cross");
    }

    #[test]
    fn bullish_filter_can_be_true_without_cross_event() {
        let mut prices = vec![100.0; 30];
        for i in 0..20 {
            prices.push(95.0 + i as f64);
        }
        let candles: Vec<Candle> = prices
            .into_iter()
            .enumerate()
            .map(|(i, p)| make_candle(p, i as i64))
            .collect();

        let p = params();
        let mut seen_cross = false;
        let mut found_state_only = false;

        for i in (p.warmup() + 1)..candles.len() {
            let window = &candles[..=i];
            if let Some(ports) = p.compute(window) {
                if ports["bullish_cross"] {
                    seen_cross = true;
                    continue;
                }

                if seen_cross
                    && ports["bullish"]
                    && !ports["bullish_cross"]
                    && !ports["bearish_cross"]
                {
                    found_state_only = true;
                    break;
                }
            }
        }

        assert!(
            found_state_only,
            "expected bullish filter state without a cross event"
        );
    }
}
