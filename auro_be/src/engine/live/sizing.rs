use serde::Serialize;
use std::collections::HashMap;

use crate::engine::types::Direction;
use crate::state::AppState;
use crate::state::LastQuote;

pub const MAX_RISK_PCT: f64 = 0.05;
pub const MAX_POSITION_PCT_OF_NAV: f64 = 0.15;
pub const MAX_CONCURRENT_PCT_OF_NAV: f64 = 0.50;
/// Ceiling on a strategy's `max_notional_pct` override — the paper behind
/// the first override user (Zarattini et al. 2024 noise-area) caps leverage
/// at 4×.
pub const MAX_NOTIONAL_OVERRIDE_PCT: f64 = 4.0;
/// Oldest price an entry is sized and stopped on: with the stream quiet for
/// longer, the price (and FX rate) may no longer be the market.
pub const MAX_QUOTE_AGE_SECONDS: i64 = 120;
/// Oldest account snapshot an entry is sized on (it refreshes every minute).
pub const MAX_ACCOUNT_AGE_SECONDS: i64 = 300;

pub struct SizingInput {
    pub equity: f64,
    pub risk_pct: f64,
    /// Per-position notional ceiling as a fraction of NAV.
    pub max_position_pct: f64,
    pub entry_price: f64,
    pub sl_price: f64,
    pub quote_to_home_rate: f64,
    /// Decimal places OANDA accepts for this instrument's units.
    pub units_precision: i32,
    pub instrument_min_units: f64,
    pub instrument_max_units: Option<f64>,
    pub instrument_policy_max_units: Option<f64>,
}

#[derive(Debug, Clone)]
pub enum SizingDecision {
    Place {
        units: f64,
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
    MissingInstrumentMetadata,
    StaleQuote,
    StaleAccount,
    InvalidOpenPositionUnits,
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
            SkipReason::MissingInstrumentMetadata => "missing_instrument_metadata",
            SkipReason::StaleQuote => "stale_quote",
            SkipReason::StaleAccount => "stale_account",
            SkipReason::InvalidOpenPositionUnits => "invalid_open_position_units",
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
    pub clamped_units: f64,
    pub clamps_applied: Vec<String>,
    pub notional_pct_of_nav: f64,
}

/// A sized order: signed units formatted to the instrument's precision, ready
/// for OANDA, plus the audit record of how they were derived.
#[derive(Debug, Clone)]
pub struct SizedEntry {
    pub units: String,
    pub metadata: SizingMetadata,
}

/// Size a new entry at `risk_pct` of NAV given its stop. The single sizing
/// path: every live entry goes through here. `max_notional_pct` is the
/// strategy's override of the per-position cap; it also lifts the book-wide
/// ceiling for this entry only, so a strategy allowed 150% alone can still
/// open when the rest of the book is flat — but never stacks on top of it.
pub async fn size_entry(
    state: &AppState,
    instrument: &str,
    direction: Direction,
    risk_pct: f64,
    max_notional_pct: Option<f64>,
    entry_price: f64,
    sl_price: f64,
) -> Result<SizedEntry, SkipReason> {
    let meta = state
        .live
        .instrument_metadata
        .read()
        .await
        .get(instrument)
        .cloned()
        .ok_or(SkipReason::MissingInstrumentMetadata)?;
    let account = state
        .live
        .account
        .read()
        .await
        .clone()
        .ok_or(SkipReason::NavUnavailable)?;
    let now = chrono::Utc::now();
    if (now - account.last_updated).num_seconds() > MAX_ACCOUNT_AGE_SECONDS {
        return Err(SkipReason::StaleAccount);
    }
    let quotes: HashMap<String, LastQuote> = state
        .live
        .last_quotes
        .read()
        .await
        .iter()
        .filter(|(_, q)| (now - q.at).num_seconds() <= MAX_QUOTE_AGE_SECONDS)
        .map(|(k, q)| (k.clone(), q.clone()))
        .collect();
    if !quotes.contains_key(instrument) {
        return Err(SkipReason::StaleQuote);
    }
    let fx_rate = quote_currency(instrument)
        .and_then(|quote| quote_to_home_rate(&quotes, quote, &account.currency))
        .ok_or(SkipReason::FxRateUnavailable)?;

    let max_position_pct = max_notional_pct.unwrap_or(MAX_POSITION_PCT_OF_NAV);
    let decision = compute_units(SizingInput {
        equity: account.nav,
        risk_pct,
        max_position_pct,
        entry_price,
        sl_price,
        quote_to_home_rate: fx_rate,
        units_precision: meta.trade_units_precision,
        instrument_min_units: meta.min_trade_size,
        instrument_max_units: meta.max_trade_size,
        instrument_policy_max_units: meta.policy_max_units,
    });

    let (units, metadata) = match decision {
        SizingDecision::Place { units, metadata } => (units, metadata),
        SizingDecision::Skip { reason, metadata } => {
            tracing::warn!(
                "[SIZING] {} skip reason={} equity={} risk_pct={} raw_units={} fx_rate={}",
                instrument,
                reason.as_str(),
                account.nav,
                risk_pct,
                metadata.raw_units,
                metadata.quote_to_home_rate
            );
            return Err(reason);
        }
    };

    let new_notional = units * entry_price.abs() * fx_rate;
    check_concurrent_exposure(
        state,
        new_notional,
        account.nav,
        &account.currency,
        MAX_CONCURRENT_PCT_OF_NAV.max(max_position_pct),
    )
    .await?;

    tracing::info!(
        "[SIZING] {} place units={} equity={} risk_pct={} sl_dist={} fx_rate={} notional_pct={} clamps={:?}",
        instrument,
        units,
        account.nav,
        risk_pct,
        metadata.sl_distance,
        metadata.quote_to_home_rate,
        metadata.notional_pct_of_nav,
        metadata.clamps_applied
    );

    let signed = match direction {
        Direction::Long => units,
        Direction::Short => -units,
    };
    Ok(SizedEntry {
        units: format_units(signed, meta.trade_units_precision),
        metadata,
    })
}

/// Units as OANDA expects them: exactly `precision` decimal places.
pub fn format_units(units: f64, precision: i32) -> String {
    format!("{:.*}", precision.max(0) as usize, units)
}

/// Round down to `precision` decimal places, never up — rounding up would
/// exceed the risk budget. The epsilon absorbs float noise like 2.9999999.
fn floor_to_precision(value: f64, precision: i32) -> f64 {
    let scale = 10f64.powi(precision.max(0));
    (value * scale + 1e-9).floor() / scale
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

pub fn compute_units(input: SizingInput) -> SizingDecision {
    let sl_distance = (input.entry_price - input.sl_price).abs();

    let mut metadata = SizingMetadata {
        equity_at_decision: input.equity,
        risk_pct: input.risk_pct,
        entry_price: input.entry_price,
        sl_price: input.sl_price,
        sl_distance,
        quote_to_home_rate: input.quote_to_home_rate,
        raw_units: 0.0,
        clamped_units: 0.0,
        clamps_applied: Vec::new(),
        notional_pct_of_nav: 0.0,
    };

    let skip = |reason, metadata| SizingDecision::Skip { reason, metadata };

    if input.risk_pct <= 0.0 || input.risk_pct > MAX_RISK_PCT {
        return skip(SkipReason::InvalidRiskPct, metadata);
    }
    if input.equity <= 0.0 {
        return skip(SkipReason::NavUnavailable, metadata);
    }
    if sl_distance == 0.0 {
        return skip(SkipReason::ZeroSlDistance, metadata);
    }
    if !input.quote_to_home_rate.is_finite() || input.quote_to_home_rate <= 0.0 {
        return skip(SkipReason::FxRateUnavailable, metadata);
    }

    let raw_units = (input.equity * input.risk_pct) / (sl_distance * input.quote_to_home_rate);
    metadata.raw_units = raw_units;
    let mut units = floor_to_precision(raw_units, input.units_precision);

    // Each cap is compared against the computed units so clamps_applied
    // records every cap that would have constrained sizing, even when two caps
    // happen to tie. The final value is the min of all caps that are set.
    let caps = [
        ("instrument_max", input.instrument_max_units),
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

    let notional = units * input.entry_price.abs() * input.quote_to_home_rate;
    metadata.notional_pct_of_nav = notional / input.equity;

    if metadata.notional_pct_of_nav > input.max_position_pct {
        return skip(SkipReason::ExceedsMaxPositionPct, metadata);
    }
    if input
        .instrument_policy_max_units
        .is_some_and(|cap| cap < input.instrument_min_units)
    {
        return skip(SkipReason::PolicyBelowMinimum, metadata);
    }
    if units < input.instrument_min_units {
        return skip(SkipReason::BelowMinimumUnits, metadata);
    }

    SizingDecision::Place { units, metadata }
}

pub async fn check_concurrent_exposure(
    state: &AppState,
    new_notional: f64,
    equity: f64,
    home_currency: &str,
    max_total_pct: f64,
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
            // An unreadable size can't be counted as zero exposure: refuse
            // the new entry rather than understate what's already open.
            let units = pos
                .units
                .parse::<f64>()
                .map_err(|_| SkipReason::InvalidOpenPositionUnits)?
                .abs();
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
    if total_pct > max_total_pct {
        return Err(SkipReason::ExceedsConcurrentExposure);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_input() -> SizingInput {
        SizingInput {
            equity: 100_000.0,
            risk_pct: 0.01,
            max_position_pct: MAX_POSITION_PCT_OF_NAV,
            entry_price: 50.0,
            sl_price: 45.0,
            quote_to_home_rate: 1.0,
            units_precision: 0,
            instrument_min_units: 1.0,
            instrument_max_units: None,
            instrument_policy_max_units: None,
        }
    }

    #[test]
    fn happy_path_normal_sizing() {
        let input = make_input();
        let decision = compute_units(input);
        match decision {
            SizingDecision::Place { units, .. } => assert_eq!(units, 200.0),
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
            SizingDecision::Place { units, .. } => assert_eq!(units, 142.0),
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
        input.instrument_max_units = Some(150.0);

        let decision = compute_units(input);
        match decision {
            SizingDecision::Place { units, metadata } => {
                assert_eq!(units, 150.0);
                assert!(metadata
                    .clamps_applied
                    .iter()
                    .any(|c| c == "instrument_max"));
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
        input.instrument_min_units = 20_000.0;

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
    fn policy_cap_clamps_units() {
        let mut input = make_input();
        input.instrument_policy_max_units = Some(10.0);

        let decision = compute_units(input);
        match decision {
            SizingDecision::Place { units, metadata } => {
                assert_eq!(units, 10.0);
                assert!(metadata.clamps_applied.iter().any(|c| c == "policy_cap"));
            }
            SizingDecision::Skip { reason, .. } => panic!("unexpected skip: {:?}", reason),
        }
    }

    #[test]
    fn policy_cap_below_oanda_min_skips() {
        let mut input = make_input();
        input.instrument_policy_max_units = Some(1.0);
        input.instrument_min_units = 10.0;

        let decision = compute_units(input);
        match decision {
            SizingDecision::Skip { reason, .. } => {
                assert_eq!(reason, SkipReason::PolicyBelowMinimum)
            }
            SizingDecision::Place { .. } => panic!("expected policy skip"),
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
            corrected_units > (uncorrected_units * 100.0 - 1.0),
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
    fn fractional_precision_sizes_index_cfds_below_one_unit() {
        // 1% of 87k NAV, 1530-point stop, CAD home at 1.4 per USD:
        // 870 / (1530 * 1.4) = 0.406 units -> floored to 0.4 at precision 1.
        let input = SizingInput {
            equity: 87_000.0,
            risk_pct: 0.01,
            max_position_pct: MAX_POSITION_PCT_OF_NAV,
            entry_price: 30_592.0,
            sl_price: 29_062.0,
            quote_to_home_rate: 1.4,
            units_precision: 1,
            instrument_min_units: 0.1,
            instrument_max_units: None,
            instrument_policy_max_units: Some(1.0),
        };
        match compute_units(input) {
            SizingDecision::Skip { reason, metadata } => {
                // 0.4 units of NAS100 is ~20% of NAV: the 15% cap rejects it.
                assert_eq!(reason, SkipReason::ExceedsMaxPositionPct);
                assert_eq!(metadata.clamped_units, 0.4);
            }
            SizingDecision::Place { units, .. } => panic!("expected cap skip, got {units}"),
        }
    }

    #[test]
    fn strategy_notional_override_lifts_position_cap() {
        // Same NAS100 entry as above, but the strategy allows 150% of NAV.
        let input = SizingInput {
            equity: 87_000.0,
            risk_pct: 0.01,
            max_position_pct: 1.5,
            entry_price: 30_592.0,
            sl_price: 29_062.0,
            quote_to_home_rate: 1.4,
            units_precision: 1,
            instrument_min_units: 0.1,
            instrument_max_units: None,
            instrument_policy_max_units: Some(1.0),
        };
        match compute_units(input) {
            SizingDecision::Place { units, .. } => assert_eq!(units, 0.4),
            SizingDecision::Skip { reason, .. } => panic!("unexpected skip: {:?}", reason),
        }
    }

    #[test]
    fn fractional_precision_rounds_down_never_up() {
        assert_eq!(floor_to_precision(0.29, 2), 0.29); // 0.29 * 100 = 28.999999999999996
        assert_eq!(floor_to_precision(0.39, 1), 0.3);
        assert_eq!(floor_to_precision(142.857, 0), 142.0);
        assert_eq!(format_units(-0.3, 1), "-0.3");
        assert_eq!(format_units(1000.0, 0), "1000");
    }

    #[tokio::test]
    async fn concurrent_exposure_limit_skips() {
        use crate::engine::types::{Granularity, OpenPosition, StopLossState};

        let state = AppState::for_tests_without_db();
        {
            let mut positions = state.live.open_positions.write().await;
            for idx in 0..6 {
                let trade_id = format!("t{idx}");
                positions.insert(
                    trade_id.clone(),
                    OpenPosition {
                        strategy_id: uuid::Uuid::new_v4(),
                        trade_id,
                        instrument: "EUR_USD".to_string(),
                        granularity: Granularity::H1,
                        direction: Direction::Long,
                        entry_price: 1.0,
                        entry_time: chrono::Utc::now(),
                        units: "8000".to_string(),
                        stop_loss_state: StopLossState::NotApplicable,
                        worst_price: 1.0,
                        best_price: 1.0,
                        strategy_type: "mean_reversion".to_string(),
                    },
                );
            }
        }
        state.live.last_quotes.write().await.insert(
            "EUR_USD".to_string(),
            LastQuote {
                mid: 1.0,
                bid: 1.0,
                ask: 1.0,
                at: chrono::Utc::now(),
            },
        );

        let result =
            check_concurrent_exposure(&state, 3_000.0, 100_000.0, "USD", MAX_CONCURRENT_PCT_OF_NAV)
                .await;
        assert_eq!(result, Err(SkipReason::ExceedsConcurrentExposure));
    }
}
