use std::collections::HashMap;

use sqlx::PgPool;

use crate::oanda::client::OandaClient;

#[derive(Debug, Clone)]
pub struct InstrumentMeta {
    pub min_trade_size: i64,
    pub max_trade_size: Option<i64>,
    pub trade_units_precision: i32,
    pub policy_max_units: Option<i64>,
    pub display_precision: i32,
    pub minimum_trailing_stop_distance: Option<f64>,
    pub maximum_trailing_stop_distance: Option<f64>,
}

fn parse_units(value: &str) -> Option<i64> {
    value.parse::<f64>().ok().map(|v| v.floor() as i64)
}

fn parse_distance(value: &str) -> Option<f64> {
    value.parse::<f64>().ok().filter(|v| *v > 0.0)
}

pub async fn load_instrument_metadata(
    oanda: &OandaClient,
    db: &PgPool,
) -> HashMap<String, InstrumentMeta> {
    let instruments = match oanda.get_instruments().await {
        Ok(instruments) => instruments,
        Err(e) => {
            tracing::warn!("[SIZING] failed to load instrument metadata: {}", e);
            return HashMap::new();
        }
    };

    let policy_caps: HashMap<String, i64> = match sqlx::query_as::<_, (String, i64)>(
        "SELECT instrument, max_units FROM instrument_unit_caps",
    )
    .fetch_all(db)
    .await
    {
        Ok(rows) => rows.into_iter().collect(),
        Err(e) => {
            tracing::warn!(
                "[SIZING] failed to load instrument policy caps from DB: {}",
                e
            );
            HashMap::new()
        }
    };

    instruments
        .into_iter()
        .map(|inst| {
            let min_trade_size = inst
                .minimum_trade_size
                .as_deref()
                .and_then(parse_units)
                .unwrap_or(1)
                .max(1);

            let max_trade_size = inst
                .maximum_order_units
                .as_deref()
                .and_then(parse_units)
                .filter(|v| *v > 0);
            let policy_max_units = policy_caps.get(&inst.name).copied();

            let trade_units_precision = inst.trade_units_precision.unwrap_or(0);
            let display_precision = inst.display_precision.unwrap_or(5);
            let minimum_trailing_stop_distance = inst
                .minimum_trailing_stop_distance
                .as_deref()
                .and_then(parse_distance);
            let maximum_trailing_stop_distance = inst
                .maximum_trailing_stop_distance
                .as_deref()
                .and_then(parse_distance);

            (
                inst.name,
                InstrumentMeta {
                    min_trade_size,
                    max_trade_size,
                    trade_units_precision,
                    policy_max_units,
                    display_precision,
                    minimum_trailing_stop_distance,
                    maximum_trailing_stop_distance,
                },
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::oanda::models::Instrument;

    #[test]
    fn parses_trailing_distance_bounds_from_oanda_instrument_json() {
        let inst: Instrument = serde_json::from_value(serde_json::json!({
            "name": "XAG_USD",
            "displayName": "Silver",
            "type": "METAL",
            "displayPrecision": 4,
            "minimumTradeSize": "1",
            "maximumOrderUnits": "100000",
            "tradeUnitsPrecision": 0,
            "minimumTrailingStopDistance": "0.00050",
            "maximumTrailingStopDistance": "1.00000"
        }))
        .unwrap();

        let meta = InstrumentMeta {
            min_trade_size: inst
                .minimum_trade_size
                .as_deref()
                .and_then(parse_units)
                .unwrap_or(1)
                .max(1),
            max_trade_size: inst
                .maximum_order_units
                .as_deref()
                .and_then(parse_units)
                .filter(|v| *v > 0),
            trade_units_precision: inst.trade_units_precision.unwrap_or(0),
            policy_max_units: None,
            display_precision: inst.display_precision.unwrap_or(5),
            minimum_trailing_stop_distance: inst
                .minimum_trailing_stop_distance
                .as_deref()
                .and_then(parse_distance),
            maximum_trailing_stop_distance: inst
                .maximum_trailing_stop_distance
                .as_deref()
                .and_then(parse_distance),
        };

        assert_eq!(meta.display_precision, 4);
        assert_eq!(meta.minimum_trailing_stop_distance, Some(0.0005));
        assert_eq!(meta.maximum_trailing_stop_distance, Some(1.0));
    }
}
