//! Fast stochastic: where the close sits in the `period`-bar high–low range,
//! 0 to 100 (%K), and its `signal_period`-bar average (%D). `oversold` /
//! `overbought`: %K below / above the levels. `cross_up` / `cross_down`: %K
//! crosses %D (inclusive on the prior bar, strict on the current one, the
//! TF cross convention).

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::catalog::{port, Block, Level, Series, Setting, SIGNAL_LINE_WHY};
use crate::engine::indicators;
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

fn default_period() -> usize {
    14
}

fn default_signal_period() -> usize {
    3
}

fn default_oversold() -> f64 {
    20.0
}

fn default_overbought() -> f64 {
    80.0
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct StochasticParams {
    #[serde(default = "default_period")]
    pub period: usize,
    #[serde(default = "default_signal_period")]
    pub signal_period: usize,
    #[serde(default = "default_oversold")]
    pub oversold: f64,
    #[serde(default = "default_overbought")]
    pub overbought: f64,
}

const STOCHASTIC_LEVEL_WHY: &str = "the stochastic only reads between 0 and 100";

/// This block in the catalog (`engine::catalog`).
pub(crate) fn catalog() -> Block {
    Block {
        kind: "Stochastic",
        key: "st",
        name: "Stochastic",
        watches: "Where the price closed within its recent high-to-low range, from 0 (at the low) to 100 (at the high), plus a smoothed copy of that line. Near the bottom of its range for a while often means it's stretched down.",
        settings: vec![
            Setting::int("period", "Bars", 14, "The range is the high and low of this many bars."),
            Setting::int(
                "signal_period",
                "Smoothing",
                3,
                "Bars to average into the second line. More is smoother but slower.",
            )
            .at_least(2.0, SIGNAL_LINE_WHY),
            Setting::float(
                "oversold",
                "Oversold below",
                20,
                "Lower means fewer, more extreme dips count.",
            )
            .between(0.0, 100.0, STOCHASTIC_LEVEL_WHY),
            Setting::float(
                "overbought",
                "Overbought above",
                80,
                "Higher means fewer, more extreme spikes count.",
            )
            .between(0.0, 100.0, STOCHASTIC_LEVEL_WHY),
        ],
        ports: vec![
            port("oversold", "the stochastic (where the price sits in its {period:bars} range) is below {oversold}"),
            port("overbought", "the stochastic (where the price sits in its {period:bars} range) is above {overbought}"),
            port("cross_up", "the stochastic (where the price sits in its {period:bars} range) crosses above its smoothed line"),
            port("cross_down", "the stochastic (where the price sits in its {period:bars} range) crosses below its smoothed line"),
        ],
        series: vec![Series::panel(
            "k",
            "Stochastic",
            vec![Level::Setting("oversold"), Level::Setting("overbought")],
        )
        .range(0.0, 100.0)
        .with("d")],
        stop: None,
    }
}

impl Signaler for StochasticParams {
    fn warmup(&self) -> usize {
        self.period + self.signal_period
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        let (_newest, earlier) = candles.split_last()?;
        let now = indicators::stochastic(candles, self.period, self.signal_period)?;
        let before = indicators::stochastic(earlier, self.period, self.signal_period)?;
        Some(HashMap::from([
            ("oversold".to_string(), now.k < self.oversold),
            ("overbought".to_string(), now.k > self.overbought),
            (
                "cross_up".to_string(),
                before.k <= before.d && now.k > now.d,
            ),
            (
                "cross_down".to_string(),
                before.k >= before.d && now.k < now.d,
            ),
        ]))
    }

    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        indicators::stochastic(candles, self.period, self.signal_period)
            .map(|s| HashMap::from([("k".to_string(), s.k), ("d".to_string(), s.d)]))
            .unwrap_or_default()
    }

    fn entry_reason(&self, candles: &[Candle], _direction: Direction) -> EntryReason {
        EntryReason::Indicator {
            name: "stochastic_k",
            value: indicators::stochastic(candles, self.period, self.signal_period)
                .map_or(50.0, |s| s.k),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::test_candles::daily as candles;

    fn params() -> StochasticParams {
        StochasticParams {
            period: 3,
            signal_period: 2,
            oversold: 20.0,
            overbought: 80.0,
        }
    }

    #[test]
    fn a_close_at_the_bottom_of_the_range_is_oversold() {
        let ports = params()
            .compute(&candles(&[100.0, 104.0, 102.0, 101.0, 99.0]))
            .unwrap();
        assert!(ports["oversold"] && !ports["overbought"]);
    }

    #[test]
    fn no_candles_is_no_signal() {
        assert!(params().compute(&[]).is_none());
    }

    #[test]
    fn k_crossing_above_d_is_a_cross_up() {
        let ports = params()
            .compute(&candles(&[110.0, 100.0, 95.0, 90.0, 105.0]))
            .unwrap();
        assert!(ports["cross_up"] && !ports["cross_down"]);
    }
}
