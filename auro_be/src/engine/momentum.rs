//! Time-series momentum: the sign of the return over the last `lookback`
//! bars (Moskowitz, Ooi & Pedersen 2012 use the trailing 12-month return).
//! `up` / `down` are strict (a flat return signals neither), matching the TF
//! strict-current convention.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::engine::catalog::{port, Block, Level, Series, Setting};
use crate::engine::indicators;
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct MomentumParams {
    pub lookback: usize,
}

/// This block in the catalog (`engine::catalog`).
pub(crate) fn catalog() -> Block {
    Block {
        kind: "Momentum",
        key: "mo",
        name: "Momentum",
        watches: "Whether the price is higher or lower than it was a number of bars ago.",
        settings: vec![Setting::int(
            "lookback",
            "Bars back",
            20,
            "More bars look at a longer-term direction.",
        )],
        ports: vec![
            port("up", "the price is higher than {lookback:bars} ago"),
            port("down", "the price is lower than {lookback:bars} ago"),
        ],
        series: vec![Series::panel(
            "roc",
            "Change from then (%)",
            vec![Level::At(0.0)],
        )],
        stop: None,
    }
}

impl Signaler for MomentumParams {
    fn warmup(&self) -> usize {
        self.lookback + 1
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        let roc = indicators::rate_of_change(candles, self.lookback)?;
        Some(HashMap::from([
            ("up".to_string(), roc > 0.0),
            ("down".to_string(), roc < 0.0),
        ]))
    }

    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        indicators::rate_of_change(candles, self.lookback)
            .map(|roc| HashMap::from([("roc".to_string(), roc)]))
            .unwrap_or_default()
    }

    fn entry_reason(&self, candles: &[Candle], _direction: Direction) -> EntryReason {
        EntryReason::Momentum {
            roc_pct: indicators::rate_of_change(candles, self.lookback).unwrap_or(0.0),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::test_candles::daily as candles;

    #[test]
    fn up_when_close_above_lookback_close() {
        let p = MomentumParams { lookback: 3 };
        let ports = p.compute(&candles(&[100.0, 90.0, 95.0, 101.0])).unwrap();
        assert!(ports["up"] && !ports["down"]);
    }

    #[test]
    fn flat_return_signals_neither() {
        let p = MomentumParams { lookback: 2 };
        let ports = p.compute(&candles(&[100.0, 120.0, 100.0])).unwrap();
        assert!(!ports["up"] && !ports["down"]);
    }

    #[test]
    fn too_few_candles_is_none() {
        assert!(MomentumParams { lookback: 3 }
            .compute(&candles(&[1.0, 2.0, 3.0]))
            .is_none());
    }
}
