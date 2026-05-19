use serde::Serialize;

use crate::state::AppState;

pub const DEFAULT_RISK_PCT: f64 = 0.01;
pub const MAX_RISK_PCT: f64 = 0.05;
pub const MAX_POSITION_PCT_OF_NAV: f64 = 0.15;
pub const MAX_CONCURRENT_PCT_OF_NAV: f64 = 0.50;

pub struct SizingInput<'a> {
    pub equity: f64,
    pub risk_pct: f64,
    pub entry_price: f64,
    pub sl_price: f64,
    pub instrument: &'a str,
    pub instrument_min_units: i64,
    pub instrument_max_units: Option<i64>,
    pub strategy_max_units: Option<i64>,
}

#[derive(Debug, Clone)]
pub enum SizingDecision {
    Place {
        units: i64,
        metadata: SizingMetadata,
    },
    Skip {
        reason: SkipReason,
        metadata: SizingMetadata,
    },
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SkipReason {
    InvalidRiskPct,
    ZeroSlDistance,
    BelowMinimumUnits,
    ExceedsMaxPositionPct,
    ExceedsConcurrentExposure,
    NavUnavailable,
}

impl SkipReason {
    pub fn as_str(&self) -> &'static str {
        match self {
            SkipReason::InvalidRiskPct => "invalid_risk_pct",
            SkipReason::ZeroSlDistance => "zero_sl_distance",
            SkipReason::BelowMinimumUnits => "below_minimum_units",
            SkipReason::ExceedsMaxPositionPct => "exceeds_max_position_pct",
            SkipReason::ExceedsConcurrentExposure => "exceeds_concurrent_exposure",
            SkipReason::NavUnavailable => "nav_unavailable",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct SizingMetadata {
    pub equity_at_decision: f64,
    pub risk_pct: f64,
    pub entry_price: f64,
    pub sl_price: f64,
    pub sl_distance: f64,
    pub raw_units: f64,
    pub clamped_units: i64,
    pub clamps_applied: Vec<String>,
    pub notional_pct_of_nav: f64,
}

pub fn compute_units(input: SizingInput<'_>) -> SizingDecision {
    let sl_distance = (input.entry_price - input.sl_price).abs();

    let mut metadata = SizingMetadata {
        equity_at_decision: input.equity,
        risk_pct: input.risk_pct,
        entry_price: input.entry_price,
        sl_price: input.sl_price,
        sl_distance,
        raw_units: 0.0,
        clamped_units: 0,
        clamps_applied: Vec::new(),
        notional_pct_of_nav: 0.0,
    };

    if input.risk_pct <= 0.0 || input.risk_pct > MAX_RISK_PCT {
        return SizingDecision::Skip {
            reason: SkipReason::InvalidRiskPct,
            metadata,
        };
    }

    if input.equity <= 0.0 {
        return SizingDecision::Skip {
            reason: SkipReason::NavUnavailable,
            metadata,
        };
    }

    if sl_distance == 0.0 {
        return SizingDecision::Skip {
            reason: SkipReason::ZeroSlDistance,
            metadata,
        };
    }

    let raw_units = (input.equity * input.risk_pct) / sl_distance;
    let mut units = raw_units.floor() as i64;

    metadata.raw_units = raw_units;

    if let Some(cap) = input.instrument_max_units {
        if units > cap {
            units = cap;
            metadata.clamps_applied.push("instrument_max".to_string());
        }
    }

    if let Some(cap) = input.strategy_max_units {
        if units > cap {
            units = cap;
            metadata.clamps_applied.push("strategy_max".to_string());
        }
    }

    metadata.clamped_units = units;

    let notional = (units as f64).abs() * input.entry_price.abs();
    metadata.notional_pct_of_nav = notional / input.equity;

    if metadata.notional_pct_of_nav > MAX_POSITION_PCT_OF_NAV {
        return SizingDecision::Skip {
            reason: SkipReason::ExceedsMaxPositionPct,
            metadata,
        };
    }

    if units < input.instrument_min_units {
        return SizingDecision::Skip {
            reason: SkipReason::BelowMinimumUnits,
            metadata,
        };
    }

    SizingDecision::Place { units, metadata }
}

pub async fn check_concurrent_exposure(
    state: &AppState,
    new_notional: f64,
    equity: f64,
) -> Result<(), SkipReason> {
    if equity <= 0.0 {
        return Err(SkipReason::NavUnavailable);
    }

    let positions_snapshot = {
        let positions = state.live.open_positions.read().await;
        positions.values().cloned().collect::<Vec<_>>()
    };

    let quotes_snapshot = state.live.last_quotes.read().await.clone();

    let existing_notional = positions_snapshot
        .iter()
        .map(|pos| {
            let units = pos.units.parse::<f64>().unwrap_or(0.0).abs();
            let price = quotes_snapshot
                .get(&pos.instrument)
                .map(|q| q.mid)
                .unwrap_or(pos.entry_price)
                .abs();
            units * price
        })
        .sum::<f64>();

    let total_pct = (existing_notional + new_notional.abs()) / equity;
    if total_pct > MAX_CONCURRENT_PCT_OF_NAV {
        return Err(SkipReason::ExceedsConcurrentExposure);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_input() -> SizingInput<'static> {
        SizingInput {
            equity: 100_000.0,
            risk_pct: DEFAULT_RISK_PCT,
            entry_price: 50.0,
            sl_price: 45.0,
            instrument: "EUR_USD",
            instrument_min_units: 1,
            instrument_max_units: None,
            strategy_max_units: None,
        }
    }

    #[test]
    fn happy_path_normal_sizing() {
        let input = make_input();
        let decision = compute_units(input);
        match decision {
            SizingDecision::Place { units, .. } => assert_eq!(units, 200),
            SizingDecision::Skip { reason, .. } => panic!("unexpected skip: {:?}", reason),
        }
    }

    #[test]
    fn floor_rounds_down_not_up() {
        let mut input = make_input();
        input.entry_price = 10.0;
        input.sl_price = 3.0;

        let decision = compute_units(input);
        match decision {
            SizingDecision::Place { units, .. } => assert_eq!(units, 142),
            SizingDecision::Skip { reason, .. } => panic!("unexpected skip: {:?}", reason),
        }
    }

    #[test]
    fn risk_pct_above_max_skips() {
        let mut input = make_input();
        input.risk_pct = 0.051;

        let decision = compute_units(input);
        match decision {
            SizingDecision::Skip { reason, .. } => assert_eq!(reason, SkipReason::InvalidRiskPct),
            SizingDecision::Place { .. } => panic!("expected skip"),
        }
    }

    #[test]
    fn risk_pct_zero_or_negative_skips() {
        let mut input = make_input();
        input.risk_pct = 0.0;
        let decision = compute_units(input);
        match decision {
            SizingDecision::Skip { reason, .. } => assert_eq!(reason, SkipReason::InvalidRiskPct),
            SizingDecision::Place { .. } => panic!("expected skip for zero risk"),
        }

        let mut input = make_input();
        input.risk_pct = -0.01;
        let decision = compute_units(input);
        match decision {
            SizingDecision::Skip { reason, .. } => assert_eq!(reason, SkipReason::InvalidRiskPct),
            SizingDecision::Place { .. } => panic!("expected skip for negative risk"),
        }
    }

    #[test]
    fn zero_sl_distance_skips() {
        let mut input = make_input();
        input.sl_price = input.entry_price;

        let decision = compute_units(input);
        match decision {
            SizingDecision::Skip { reason, .. } => assert_eq!(reason, SkipReason::ZeroSlDistance),
            SizingDecision::Place { .. } => panic!("expected skip"),
        }
    }

    #[test]
    fn clamps_to_instrument_max() {
        let mut input = make_input();
        input.instrument_max_units = Some(150);

        let decision = compute_units(input);
        match decision {
            SizingDecision::Place { units, metadata } => {
                assert_eq!(units, 150);
                assert!(metadata
                    .clamps_applied
                    .iter()
                    .any(|c| c == "instrument_max"));
            }
            SizingDecision::Skip { reason, .. } => panic!("unexpected skip: {:?}", reason),
        }
    }

    #[test]
    fn clamps_to_strategy_max() {
        let mut input = make_input();
        input.strategy_max_units = Some(120);

        let decision = compute_units(input);
        match decision {
            SizingDecision::Place { units, metadata } => {
                assert_eq!(units, 120);
                assert!(metadata.clamps_applied.iter().any(|c| c == "strategy_max"));
            }
            SizingDecision::Skip { reason, .. } => panic!("unexpected skip: {:?}", reason),
        }
    }

    #[test]
    fn position_exceeds_max_pct_skips() {
        let mut input = make_input();
        input.entry_price = 2.0;
        input.sl_price = 1.99;

        let decision = compute_units(input);
        match decision {
            SizingDecision::Skip { reason, .. } => {
                assert_eq!(reason, SkipReason::ExceedsMaxPositionPct)
            }
            SizingDecision::Place { .. } => panic!("expected skip"),
        }
    }

    #[test]
    fn below_instrument_minimum_skips() {
        let mut input = make_input();
        input.entry_price = 1.0;
        input.sl_price = 0.9;
        input.instrument_min_units = 20_000;

        let decision = compute_units(input);
        match decision {
            SizingDecision::Skip { reason, .. } => {
                assert_eq!(reason, SkipReason::BelowMinimumUnits)
            }
            SizingDecision::Place { .. } => panic!("expected skip"),
        }
    }

    #[test]
    fn nav_unavailable_skips() {
        let mut input = make_input();
        input.equity = 0.0;

        let decision = compute_units(input);
        match decision {
            SizingDecision::Skip { reason, .. } => assert_eq!(reason, SkipReason::NavUnavailable),
            SizingDecision::Place { .. } => panic!("expected skip"),
        }
    }
}
