use std::collections::HashMap;

use sqlx::PgPool;

use crate::brokers::oanda::client::OandaClient;
use crate::brokers::oanda::models::Instrument;
use crate::db::repositories::live_queries;

/// Per-instrument trading constraints. Units are fractional: OANDA sizes some
/// instruments (e.g. index CFDs) in tenths of a unit.
#[derive(Debug, Clone)]
pub struct InstrumentMeta {
    pub min_trade_size: f64,
    pub max_trade_size: Option<f64>,
    /// Decimal places OANDA accepts for order units.
    pub trade_units_precision: i32,
    /// Auro's own per-instrument unit cap (`instrument_unit_caps`).
    pub policy_max_units: Option<f64>,
    pub display_precision: i32,
}

impl InstrumentMeta {
    fn from_oanda(inst: &Instrument, policy_max_units: Option<f64>) -> Self {
        let parse_positive = |v: &Option<String>| {
            v.as_deref()
                .and_then(|s| s.parse::<f64>().ok())
                .filter(|v| *v > 0.0)
        };
        let trade_units_precision = inst.trade_units_precision.unwrap_or(0).max(0);

        InstrumentMeta {
            min_trade_size: parse_positive(&inst.minimum_trade_size)
                .unwrap_or_else(|| 10f64.powi(-trade_units_precision)),
            max_trade_size: parse_positive(&inst.maximum_order_units),
            trade_units_precision,
            policy_max_units,
            display_precision: inst.display_precision.unwrap_or(5),
        }
    }
}

/// How often instrument metadata and policy caps are reloaded, so a failed
/// startup load (or a cap changed in the database) doesn't last until a
/// restart.
const RELOAD_EVERY: std::time::Duration = std::time::Duration::from_secs(600);

/// Reload the metadata every `RELOAD_EVERY`, keeping the old copy when a
/// load comes back empty. Runs forever; started under a supervisor.
pub async fn run_metadata_reload(state: crate::state::AppState) {
    let mut interval = tokio::time::interval(RELOAD_EVERY);
    interval.tick().await;
    loop {
        interval.tick().await;
        let fresh = load_instrument_metadata(&state.oanda, &state.db).await;
        if fresh.is_empty() {
            continue;
        }
        *state.live.instrument_metadata.write().await = fresh;
    }
}

pub async fn load_instrument_metadata(
    oanda: &OandaClient,
    db: &PgPool,
) -> HashMap<String, InstrumentMeta> {
    let instruments = match oanda.get_instruments().await {
        Ok(instruments) => instruments,
        Err(e) => {
            tracing::error!(
                "[SIZING] failed to load instrument metadata (entries skip until a reload works): {}",
                e
            );
            return HashMap::new();
        }
    };

    let policy_caps: HashMap<String, f64> = match live_queries::instrument_unit_caps(db).await {
        Ok(rows) => rows
            .into_iter()
            .map(|(instrument, cap)| (instrument, cap as f64))
            .collect(),
        // Without the caps, sizing would run uncapped: keep no metadata at
        // all instead, so entries skip until a reload reads both.
        Err(e) => {
            tracing::error!(
                "[SIZING] failed to load instrument policy caps (entries skip until a reload works): {}",
                e
            );
            return HashMap::new();
        }
    };

    instruments
        .iter()
        .map(|inst| {
            let meta = InstrumentMeta::from_oanda(inst, policy_caps.get(&inst.name).copied());
            (inst.name.clone(), meta)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn instrument(json: serde_json::Value) -> Instrument {
        serde_json::from_value(json).unwrap()
    }

    #[test]
    fn fractional_unit_instrument_keeps_fractional_minimum() {
        let meta = InstrumentMeta::from_oanda(
            &instrument(serde_json::json!({
                "name": "NAS100_USD",
                "displayName": "US Nas 100",
                "type": "CFD",
                "displayPrecision": 1,
                "minimumTradeSize": "0.1",
                "maximumOrderUnits": "2500",
                "tradeUnitsPrecision": 1
            })),
            Some(1.0),
        );

        assert_eq!(meta.min_trade_size, 0.1);
        assert_eq!(meta.max_trade_size, Some(2500.0));
        assert_eq!(meta.trade_units_precision, 1);
        assert_eq!(meta.policy_max_units, Some(1.0));
        assert_eq!(meta.display_precision, 1);
    }

    #[test]
    fn missing_minimum_defaults_to_smallest_unit_step() {
        let meta = InstrumentMeta::from_oanda(
            &instrument(serde_json::json!({
                "name": "EUR_USD",
                "displayName": "EUR/USD",
                "type": "CURRENCY",
                "tradeUnitsPrecision": 0
            })),
            None,
        );

        assert_eq!(meta.min_trade_size, 1.0);
        assert_eq!(meta.max_trade_size, None);
        assert_eq!(meta.display_precision, 5);
    }
}
