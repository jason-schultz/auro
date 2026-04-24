use axum::extract::{Query, State};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::error::AppResult;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct CandleParams {
    pub instrument: String,
    pub granularity: Option<String>,
    pub count: Option<i32>,
}

pub async fn get_candles(
    State(state): State<AppState>,
    Query(params): Query<CandleParams>,
) -> AppResult<Json<Value>> {
    let granularity = params.granularity.as_deref().unwrap_or("M1");
    let count = params.count.unwrap_or(100);

    let candles = state
        .oanda
        .get_candles(&params.instrument, granularity, Some(count), None, None)
        .await?;

    // Transform to a simpler format for the frontend
    let data: Vec<Value> = candles
        .candles
        .iter()
        .filter_map(|c| {
            let mid = c.mid.as_ref()?;
            Some(json!({
                "time": c.time,
                "open": mid.o.parse::<f64>().ok()?,
                "high": mid.h.parse::<f64>().ok()?,
                "low": mid.l.parse::<f64>().ok()?,
                "close": mid.c.parse::<f64>().ok()?,
                "volume": c.volume,
                "complete": c.complete,
            }))
        })
        .collect();

    Ok(Json(json!({
        "instrument": candles.instrument,
        "granularity": candles.granularity,
        "candles": data,
    })))
}
