//! Bollinger bands (Bollinger's original: a `period`-bar simple average with
//! a band `std_dev_mult` population standard deviations either side, 20 and
//! 2 by default). `below_band` / `above_band`: the close is outside the band.
//! `above_middle` / `below_middle`: the close against the average, inclusive
//! (the usual "back to normal" exit, per the MR inclusive-exit convention).
//! `squeeze`: the bandwidth, (upper − lower) / middle, is at or below its
//! lowest over the last `squeeze_lookback` bars, this one included
//! (Bollinger's "Squeeze": bandwidth at a six-month low, 120–125 daily
//! bars). It needs `period + squeeze_lookback − 1` bars; before that the
//! port is left out (can't compute), so a rule on it has no signal, while
//! the other ports keep the block's usual warmup.
//! `squeeze_recent` (only with `squeeze_within` set): the squeeze held on
//! any of the last `squeeze_within` bars, this one included. Rules only
//! combine ports of the same bar, and a breakout bar has usually already
//! widened the band, so "squeezed, then broke out" is
//! `squeeze_recent AND above_band`. It needs `squeeze_within − 1` more bars
//! than `squeeze`.
//! The general form, for any block, is the rule
//! `{"within": N, "rule": "b.squeeze"}` (see `strategy::PortRef`), which
//! gives the same signals; `squeeze_within` is kept for existing recipes.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::engine::catalog::{port, Block, Series, Setting, SPREAD_WHY};
use crate::engine::indicators;
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

fn default_period() -> usize {
    20
}

fn default_std_dev_mult() -> f64 {
    2.0
}

fn default_squeeze_lookback() -> usize {
    120
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct BollingerParams {
    #[serde(default = "default_period")]
    pub period: usize,
    #[serde(default = "default_std_dev_mult")]
    pub std_dev_mult: f64,
    /// Bars the squeeze compares today's bandwidth against.
    #[serde(default = "default_squeeze_lookback")]
    pub squeeze_lookback: usize,
    /// Bars `squeeze_recent` looks back over; none leaves the port out.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub squeeze_within: Option<usize>,
}

impl BollingerParams {
    /// Band width over the average for the bar at the end of `candles`.
    fn bandwidth(&self, candles: &[Candle]) -> Option<f64> {
        let (middle, std_dev) = indicators::mean_stdev(candles, self.period)?;
        (middle != 0.0).then(|| 2.0 * self.std_dev_mult * std_dev / middle)
    }

    /// The newest bandwidth is the narrowest of the last `squeeze_lookback`.
    fn squeeze(&self, candles: &[Candle]) -> Option<bool> {
        let lookback = self.squeeze_lookback;
        if lookback == 0 || candles.len() + 1 < self.period + lookback {
            return None;
        }
        let now = self.bandwidth(candles)?;
        let mut lowest = now;
        for back in 1..lookback {
            lowest = lowest.min(self.bandwidth(&candles[..candles.len() - back])?);
        }
        Some(now <= lowest)
    }

    /// The squeeze held on any of the last `squeeze_within` bars.
    fn squeeze_recent(&self, candles: &[Candle]) -> Option<bool> {
        let within = self.squeeze_within?;
        if within == 0 || candles.len() < within {
            return None;
        }
        let mut any = false;
        for back in 0..within {
            any |= self.squeeze(&candles[..candles.len() - back])?;
        }
        Some(any)
    }
}

/// This block in the catalog (`engine::catalog`).
pub(crate) fn catalog() -> Block {
    Block {
        kind: "Bollinger",
        key: "bb",
        name: "Bollinger bands",
        watches: "A band around the average price, as wide as the price's normal wobble. Closing outside the band means it has stretched further than usual; the middle line is the average it often returns to.",
        settings: vec![
            Setting::int(
                "period",
                "Bars",
                20,
                "The average and the wobble are measured over this many bars.",
            )
            .at_least(2.0, SPREAD_WHY),
            Setting::float(
                "std_dev_mult",
                "Band width",
                2.0,
                "In normal wobbles (standard deviations). Wider means only bigger stretches count.",
            ),
            Setting::int(
                "squeeze_lookback",
                "Squeeze over (bars)",
                120,
                "A squeeze is the band at its narrowest in this many bars: a quiet spell that often ends in a big move. About six months of daily bars is the usual.",
            )
            .at_least(2.0, "the narrowest band over 1 bar is always the current one"),
            Setting::int(
                "squeeze_within",
                "Squeeze in the last (bars)",
                Value::Null,
                "Leave empty to skip. Set it to use \"squeezed recently\": the squeeze held on any of this many bars, so it still counts on the bar that breaks out, when the band has already started to widen. Pair it with a close outside the band.",
            )
            .at_least(1.0, "a squeeze in the last 0 bars never fires"),
        ],
        ports: vec![
            port("below_band", "the price closes below its lower Bollinger band ({std_dev_mult} normal wobbles under its average over {period:bars})"),
            port("above_band", "the price closes above its upper Bollinger band ({std_dev_mult} normal wobbles over its average over {period:bars})"),
            port("above_middle", "the price is back up to its average over {period:bars}"),
            port("below_middle", "the price is back down to its average over {period:bars}"),
            port("squeeze", "the Bollinger bands (over {period:bars}) are the narrowest in {squeeze_lookback:bars}: a squeeze"),
            port("squeeze_recent", "the Bollinger bands (over {period:bars}) were squeezed, the narrowest in {squeeze_lookback:bars}, at some point in the last {squeeze_within:bars|1}"),
        ],
        series: vec![
            Series::price("upper", "Band top"),
            Series::price("middle", "Band middle (average)"),
            Series::price("lower", "Band bottom"),
            Series::panel("bandwidth", "Band width (share of the average)", vec![]),
        ],
        stop: None,
    }
}

impl Signaler for BollingerParams {
    fn warmup(&self) -> usize {
        self.period
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        let b = indicators::bollinger(candles, self.period, self.std_dev_mult)?;
        let close = candles.last()?.mid.close;
        let mut ports = HashMap::from([
            ("below_band".to_string(), close < b.lower),
            ("above_band".to_string(), close > b.upper),
            ("above_middle".to_string(), close >= b.middle),
            ("below_middle".to_string(), close <= b.middle),
        ]);
        if let Some(squeeze) = self.squeeze(candles) {
            ports.insert("squeeze".to_string(), squeeze);
        }
        if let Some(recent) = self.squeeze_recent(candles) {
            ports.insert("squeeze_recent".to_string(), recent);
        }
        Some(ports)
    }

    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        indicators::bollinger(candles, self.period, self.std_dev_mult)
            .map(|b| {
                let mut values = HashMap::from([
                    ("upper".to_string(), b.upper),
                    ("middle".to_string(), b.middle),
                    ("lower".to_string(), b.lower),
                ]);
                if let Some(width) = self.bandwidth(candles) {
                    values.insert("bandwidth".to_string(), width);
                }
                values
            })
            .unwrap_or_default()
    }

    fn entry_reason(&self, candles: &[Candle], _direction: Direction) -> EntryReason {
        EntryReason::Indicator {
            name: "bollinger_position",
            value: indicators::bollinger(candles, self.period, self.std_dev_mult)
                .map_or(0.5, |b| b.position),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::test_candles::daily as candles;

    fn params() -> BollingerParams {
        BollingerParams {
            period: 4,
            std_dev_mult: 1.0,
            squeeze_lookback: 120,
            squeeze_within: None,
        }
    }

    fn squeeze_params() -> BollingerParams {
        BollingerParams {
            period: 2,
            std_dev_mult: 2.0,
            squeeze_lookback: 3,
            squeeze_within: None,
        }
    }

    #[test]
    fn squeeze_is_the_narrowest_band_of_the_lookback() {
        // Period 2: each bandwidth is |a − b| / ((a + b) / 2) × 2 (2 sd = |a − b|).
        // Closes 100,104,101,102,101.5 give pairs with gaps 4, 3, 1, 0.5:
        // the last bandwidth (0.5) is the narrowest of the last three.
        let ports = squeeze_params()
            .compute(&candles(&[100.0, 104.0, 101.0, 102.0, 101.5]))
            .unwrap();
        assert!(ports["squeeze"]);
        // A wider last pair (gap 3 after gap 1) is not a squeeze.
        let ports = squeeze_params()
            .compute(&candles(&[100.0, 104.0, 103.0, 102.0, 105.0]))
            .unwrap();
        assert!(!ports["squeeze"]);
    }

    #[test]
    fn squeeze_recent_remembers_a_squeeze_through_the_breakout_bar() {
        let within = |n| BollingerParams {
            squeeze_within: Some(n),
            ..squeeze_params()
        };
        // The squeeze holds on the 101.5 bar; the jump to 110 widens the band
        // (gap 8.5), so the breakout bar itself is no squeeze.
        let bars = candles(&[100.0, 104.0, 101.0, 102.0, 101.5, 110.0]);
        let ports = within(2).compute(&bars).unwrap();
        assert!(!ports["squeeze"]);
        assert!(ports["squeeze_recent"]);
        // Looking back only over the breakout bar finds none.
        assert!(!within(1).compute(&bars).unwrap()["squeeze_recent"]);
        // Off by default: no port at all.
        assert!(!squeeze_params()
            .compute(&bars)
            .unwrap()
            .contains_key("squeeze_recent"));
    }

    #[test]
    fn squeeze_recent_matches_the_general_within_rule() {
        use crate::engine::strategy::{EntrySignal, Strategy};
        let strategy = |squeeze_within: Option<usize>, long: serde_json::Value| -> Strategy {
            serde_json::from_value(serde_json::json!({
                "strategy_id": null,
                "strategy_name": "squeeze",
                "version": "v1_composite",
                "instrument": "TEST",
                "granularity": "D",
                "components": {"b": {"type": "Bollinger", "params": {
                    "period": 2, "std_dev_mult": 2.0, "squeeze_lookback": 3,
                    "squeeze_within": squeeze_within
                }}},
                "entry": {"long": long},
                "exit": {},
                "stop": {"type": "FixedPct", "params": {"pct": -0.5}},
                "sizing": {"type": "RiskPct", "params": {"pct": 0.01}}
            }))
            .unwrap()
        };
        let closes: Vec<f64> = (0..80)
            .map(|i| 100.0 + (i as f64 * 0.9).sin() * (1.0 + (i % 7) as f64))
            .collect();
        let bars = candles(&closes);
        for within in [1, 2, 4] {
            let old = strategy(Some(within), serde_json::json!("b.squeeze_recent"));
            let general = strategy(
                None,
                serde_json::json!({"within": within, "rule": "b.squeeze"}),
            );
            let long = |s: &Strategy, bars: &[Candle]| {
                s.compute_ports(bars)
                    .is_some_and(|p| s.evaluate_entry(bars, &p) == EntrySignal::Long)
            };
            let mut fired = 0;
            // Every bar, the first ones (too few candles) included.
            for end in 1..=bars.len() {
                let window = &bars[..end];
                assert_eq!(
                    long(&old, window),
                    long(&general, window),
                    "within {within}, bar {end}"
                );
                fired += usize::from(long(&old, window));
            }
            assert!(fired > 0, "within {within} never fired");
        }
    }

    #[test]
    fn squeeze_counts_a_tie_with_the_lowest() {
        // Gaps 2, 2, 2: the newest equals the lowest.
        let ports = squeeze_params()
            .compute(&candles(&[100.0, 102.0, 100.0, 102.0]))
            .unwrap();
        assert!(ports["squeeze"]);
    }

    #[test]
    fn squeeze_is_missing_until_the_lookback_is_filled_but_the_bands_are_not() {
        // Needs period + lookback − 1 = 4 bars; with 3 only the band ports.
        let ports = squeeze_params()
            .compute(&candles(&[100.0, 104.0, 101.0]))
            .unwrap();
        assert!(!ports.contains_key("squeeze"));
        assert!(ports.contains_key("below_band"));
        assert_eq!(squeeze_params().warmup(), 2);
    }

    #[test]
    fn existing_settings_read_with_the_default_lookback_and_unchanged_ports() {
        let p: BollingerParams =
            serde_json::from_value(serde_json::json!({"period": 4, "std_dev_mult": 1.0})).unwrap();
        assert_eq!(p.squeeze_lookback, 120);
        assert_eq!(p.warmup(), 4);
        let bars = candles(&[100.0, 101.0, 100.0, 90.0]);
        let ports = p.compute(&bars).unwrap();
        let old = params().compute(&bars).unwrap();
        for port in ["below_band", "above_band", "above_middle", "below_middle"] {
            assert_eq!(ports[port], old[port], "{port}");
        }
    }

    #[test]
    fn a_close_far_below_the_average_is_below_the_band() {
        let ports = params()
            .compute(&candles(&[100.0, 101.0, 100.0, 90.0]))
            .unwrap();
        assert!(ports["below_band"] && ports["below_middle"]);
        assert!(!ports["above_band"] && !ports["above_middle"]);
    }

    #[test]
    fn series_reports_the_band_to_draw() {
        let series = params().series(&candles(&[100.0, 100.0, 100.0, 100.0]));
        assert_eq!(series["middle"], 100.0);
        assert_eq!(series["upper"], 100.0);
    }
}
