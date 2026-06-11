use serde::Serialize;
use std::collections::HashMap;

use crate::state::AppState;
use crate::state::LastQuote;

pub const DEFAULT_RISK_PCT: f64 = 0.01;
pub const MAX_RISK_PCT: f64 = 0.05;
pub const MAX_POSITION_PCT_OF_NAV: f64 = 0.15;
pub const MAX_CONCURRENT_PCT_OF_NAV: f64 = 0.50;

pub struct SizingInput<'a> {
    pub equity: f64,
    pub risk_pct: f64,
    pub entry_price: f64,
    pub sl_price: f64,
    pub quote_to_home_rate: f64,
    pub instrument: &'a str,
    pub instrument_min_units: i64,
    pub instrument_max_units: Option<i64>,
    pub instrument_policy_max_units: Option<i64>,
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
    PolicyBelowMinimum,
    ExceedsMaxPositionPct,
    ExceedsConcurrentExposure,
    NavUnavailable,
    FxRateUnavailable,
    InvalidMaxPositionSize,
}

impl SkipReason {
    pub fn as_str(&self) -> &'static str {
        match self {
            SkipReason::InvalidRiskPct => "invalid_risk_pct",
            SkipReason::ZeroSlDistance => "zero_sl_distance",
            SkipReason::BelowMinimumUnits => "below_minimum_units",
            SkipReason::PolicyBelowMinimum => "policy_below_minimum",
            SkipReason::ExceedsMaxPositionPct => "exceeds_max_position_pct",
            SkipReason::ExceedsConcurrentExposure => "exceeds_concurrent_exposure",
            SkipReason::NavUnavailable => "nav_unavailable",
            SkipReason::FxRateUnavailable => "fx_rate_unavailable",
            SkipReason::InvalidMaxPositionSize => "invalid_max_position_size",
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
    pub quote_to_home_rate: f64,
    pub raw_units: f64,
    pub clamped_units: i64,
    pub clamps_applied: Vec<String>,
    pub notional_pct_of_nav: f64,
}

/// Quote currency of an OANDA instrument ("EUR_USD" -> "USD",
/// "UK100_GBP" -> "GBP"). All OANDA names are BASE_QUOTE.
pub fn quote_currency(instrument: &str) -> Option<&str> {
    instrument.split_once('_').map(|(_, quote)| quote)
}

fn pair_rate(quotes: &HashMap<String, LastQuote>, from: &str, to: &str) -> Option<f64> {
    if from == to {
        return Some(1.0);
    }

    let direct = format!("{}_{}", from, to);
    if let Some(q) = quotes.get(&direct) {
        if q.mid.is_finite() && q.mid > 0.0 {
            return Some(q.mid);
        }
    }

    let inverse = format!("{}_{}", to, from);
    if let Some(q) = quotes.get(&inverse) {
        if q.mid.is_finite() && q.mid > 0.0 {
            return Some(1.0 / q.mid);
        }
    }

    None
}

/// Conversion rate from `quote` currency to `home` currency, derived
/// from the in-memory last_quotes map.
pub fn quote_to_home_rate(
    quotes: &HashMap<String, LastQuote>,
    quote: &str,
    home: &str,
) -> Option<f64> {
    if quote == home {
        return Some(1.0);
    }

    if let Some(rate) = pair_rate(quotes, quote, home) {
        return Some(rate);
    }

    let quote_to_usd = pair_rate(quotes, quote, "USD")?;
    let usd_to_home = pair_rate(quotes, "USD", home)?;
    Some(quote_to_usd * usd_to_home)
}

pub fn clamp_static_units(
    parsed: i64,
    policy_cap: Option<i64>,
    oanda_min: i64,
) -> Result<i64, SkipReason> {
    let parsed_abs = parsed.abs();
    let effective_abs = match policy_cap {
        Some(cap) => parsed_abs.min(cap),
        None => parsed_abs,
    };

    if let Some(cap) = policy_cap {
        if cap < oanda_min {
            return Err(SkipReason::PolicyBelowMinimum);
        }
    }

    if effective_abs < oanda_min {
        return Err(SkipReason::BelowMinimumUnits);
    }

    Ok(if parsed < 0 {
        -effective_abs
    } else {
        effective_abs
    })
}

pub fn compute_units(input: SizingInput<'_>) -> SizingDecision {
    let sl_distance = (input.entry_price - input.sl_price).abs();

    let mut metadata = SizingMetadata {
        equity_at_decision: input.equity,
        risk_pct: input.risk_pct,
        entry_price: input.entry_price,
        sl_price: input.sl_price,
        sl_distance,
        quote_to_home_rate: input.quote_to_home_rate,
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

    if !input.quote_to_home_rate.is_finite() || input.quote_to_home_rate <= 0.0 {
        return SizingDecision::Skip {
            reason: SkipReason::FxRateUnavailable,
            metadata,
        };
    }

    let raw_units = (input.equity * input.risk_pct) / (sl_distance * input.quote_to_home_rate);
    let mut units = raw_units.floor() as i64;

    metadata.raw_units = raw_units;

    // Each cap is compared against the raw computed units so clamps_applied
    // records every cap that would have constrained sizing, even when two caps
    // happen to tie. The final value is the min of all caps that are set.
    let caps = [
        ("instrument_max", input.instrument_max_units),
        ("strategy_max", input.strategy_max_units),
        ("policy_cap", input.instrument_policy_max_units),
    ];

    for (label, cap) in caps {
        if let Some(cap) = cap {
            if units > cap {
                metadata.clamps_applied.push(label.to_string());
            }
            units = units.min(cap);
        }
    }

    metadata.clamped_units = units;

    let notional = (units as f64).abs() * input.entry_price.abs() * input.quote_to_home_rate;
    metadata.notional_pct_of_nav = notional / input.equity;

    if metadata.notional_pct_of_nav > MAX_POSITION_PCT_OF_NAV {
        return SizingDecision::Skip {
            reason: SkipReason::ExceedsMaxPositionPct,
            metadata,
        };
    }

    if let Some(policy_cap) = input.instrument_policy_max_units {
        if policy_cap < input.instrument_min_units {
            return SizingDecision::Skip {
                reason: SkipReason::PolicyBelowMinimum,
                metadata,
            };
        }
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
    home_currency: &str,
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
        .map(|pos| -> Result<f64, SkipReason> {
            let units = pos.units.parse::<f64>().unwrap_or(0.0).abs();
            let price = quotes_snapshot
                .get(&pos.instrument)
                .map(|q| q.mid)
                .unwrap_or(pos.entry_price)
                .abs();
            let quote = quote_currency(&pos.instrument).ok_or(SkipReason::FxRateUnavailable)?;
            let rate = quote_to_home_rate(&quotes_snapshot, quote, home_currency)
                .ok_or(SkipReason::FxRateUnavailable)?;
            Ok(units * price * rate)
        })
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
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
            quote_to_home_rate: 1.0,
            instrument: "EUR_USD",
            instrument_min_units: 1,
            instrument_max_units: None,
            instrument_policy_max_units: None,
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

    #[test]
    fn policy_cap_clamps_strategy_max() {
        let mut input = make_input();
        input.strategy_max_units = Some(100);
        input.instrument_policy_max_units = Some(10);

        let decision = compute_units(input);
        match decision {
            SizingDecision::Place { units, metadata } => {
                assert_eq!(units, 10);
                assert!(metadata.clamps_applied.iter().any(|c| c == "policy_cap"));
            }
            SizingDecision::Skip { reason, .. } => panic!("unexpected skip: {:?}", reason),
        }
    }

    #[test]
    fn policy_cap_below_oanda_min_skips() {
        let mut input = make_input();
        input.instrument_policy_max_units = Some(1);
        input.instrument_min_units = 10;

        let decision = compute_units(input);
        match decision {
            SizingDecision::Skip { reason, .. } => {
                assert_eq!(reason, SkipReason::PolicyBelowMinimum)
            }
            SizingDecision::Place { .. } => panic!("expected policy skip"),
        }
    }

    #[test]
    fn no_policy_cap_unchanged() {
        let mut input = make_input();
        input.strategy_max_units = Some(120);
        input.instrument_policy_max_units = None;

        let decision = compute_units(input);
        match decision {
            SizingDecision::Place { units, metadata } => {
                assert_eq!(units, 120);
                assert!(!metadata.clamps_applied.iter().any(|c| c == "policy_cap"));
                assert!(metadata.clamps_applied.iter().any(|c| c == "strategy_max"));
            }
            SizingDecision::Skip { reason, .. } => panic!("unexpected skip: {:?}", reason),
        }
    }

    #[test]
    fn quote_currency_extracts_quote_side() {
        assert_eq!(quote_currency("EUR_USD"), Some("USD"));
        assert_eq!(quote_currency("UK100_GBP"), Some("GBP"));
        assert_eq!(quote_currency("MALFORMED"), None);
    }

    #[test]
    fn quote_to_home_direct_pair() {
        let mut quotes = HashMap::new();
        quotes.insert(
            "USD_CAD".to_string(),
            LastQuote {
                mid: 1.37,
                bid: 1.3699,
                ask: 1.3701,
                at: chrono::Utc::now(),
            },
        );

        assert_eq!(quote_to_home_rate(&quotes, "USD", "CAD"), Some(1.37));
    }

    #[test]
    fn quote_to_home_inverse_pair() {
        let mut quotes = HashMap::new();
        quotes.insert(
            "CAD_USD".to_string(),
            LastQuote {
                mid: 0.73,
                bid: 0.7299,
                ask: 0.7301,
                at: chrono::Utc::now(),
            },
        );

        let rate = quote_to_home_rate(&quotes, "USD", "CAD").unwrap();
        assert!((rate - (1.0 / 0.73)).abs() < 1e-9);
    }

    #[test]
    fn quote_to_home_cross_via_usd() {
        let mut quotes = HashMap::new();
        quotes.insert(
            "GBP_USD".to_string(),
            LastQuote {
                mid: 1.25,
                bid: 1.2499,
                ask: 1.2501,
                at: chrono::Utc::now(),
            },
        );
        quotes.insert(
            "USD_CAD".to_string(),
            LastQuote {
                mid: 1.37,
                bid: 1.3699,
                ask: 1.3701,
                at: chrono::Utc::now(),
            },
        );

        let rate = quote_to_home_rate(&quotes, "GBP", "CAD").unwrap();
        assert!((rate - (1.25 * 1.37)).abs() < 1e-9);
    }

    #[test]
    fn quote_to_home_quote_equals_home() {
        let quotes = HashMap::new();
        assert_eq!(quote_to_home_rate(&quotes, "CAD", "CAD"), Some(1.0));
    }

    #[test]
    fn quote_to_home_unresolvable_returns_none() {
        let quotes = HashMap::new();
        assert_eq!(quote_to_home_rate(&quotes, "JPY", "CAD"), None);
    }

    #[test]
    fn jpy_rate_scales_units_up_vs_uncorrected_math() {
        let mut corrected = make_input();
        corrected.entry_price = 160.0;
        corrected.sl_price = 80.0;
        corrected.quote_to_home_rate = 0.009;

        let corrected_units = match compute_units(corrected) {
            SizingDecision::Place { units, .. } => units,
            SizingDecision::Skip { reason, .. } => panic!("unexpected skip: {:?}", reason),
        };

        let mut uncorrected = make_input();
        uncorrected.entry_price = 160.0;
        uncorrected.sl_price = 80.0;
        uncorrected.quote_to_home_rate = 1.0;

        let uncorrected_units = match compute_units(uncorrected) {
            SizingDecision::Place { units, .. } => units,
            SizingDecision::Skip { reason, .. } => panic!("unexpected skip: {:?}", reason),
        };

        assert!(
            corrected_units > (uncorrected_units * 100 - 1),
            "expected corrected units to be ~100x larger, got corrected={} uncorrected={}",
            corrected_units,
            uncorrected_units
        );
    }

    #[test]
    fn converted_notional_cap_skips_when_home_notional_too_large() {
        let mut input = make_input();
        input.entry_price = 10.0;
        input.sl_price = 9.99;
        input.quote_to_home_rate = 2.0;

        let decision = compute_units(input);
        match decision {
            SizingDecision::Skip { reason, .. } => {
                assert_eq!(reason, SkipReason::ExceedsMaxPositionPct)
            }
            SizingDecision::Place { .. } => panic!("expected max position cap skip"),
        }
    }

    #[test]
    fn clamp_static_units_respects_policy_and_min() {
        assert_eq!(clamp_static_units(1000, Some(200), 1).unwrap(), 200);
        assert_eq!(clamp_static_units(-1000, Some(200), 1).unwrap(), -200);
        assert_eq!(
            clamp_static_units(1000, Some(5), 10).unwrap_err(),
            SkipReason::PolicyBelowMinimum
        );
        assert_eq!(
            clamp_static_units(5, None, 10).unwrap_err(),
            SkipReason::BelowMinimumUnits
        );
    }
}
