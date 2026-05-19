use std::collections::HashMap;

use crate::oanda::client::OandaClient;

#[derive(Debug, Clone)]
pub struct InstrumentMeta {
    pub min_trade_size: i64,
    pub max_trade_size: Option<i64>,
    pub trade_units_precision: i32,
}

fn parse_units(value: &str) -> Option<i64> {
    value.parse::<f64>().ok().map(|v| v.floor() as i64)
}

pub async fn load_instrument_metadata(oanda: &OandaClient) -> HashMap<String, InstrumentMeta> {
    let instruments = match oanda.get_instruments().await {
        Ok(instruments) => instruments,
        Err(e) => {
            tracing::warn!("[SIZING] failed to load instrument metadata: {}", e);
            return HashMap::new();
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

            let trade_units_precision = inst.trade_units_precision.unwrap_or(0);

            (
                inst.name,
                InstrumentMeta {
                    min_trade_size,
                    max_trade_size,
                    trade_units_precision,
                },
            )
        })
        .collect()
}
