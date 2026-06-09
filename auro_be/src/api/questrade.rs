use axum::extract::{Query, State};
use axum::Json;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::brokers::questrade::models::EquityCandle;
use crate::error::{AppError, AppResult};
use crate::state::AppState;

pub async fn status(State(state): State<AppState>) -> AppResult<Json<Value>> {
    let Some(qt) = state.questrade.as_ref() else {
        return Ok(Json(json!({ "connected": false, "accounts": [] })));
    };

    let mut client = qt.lock().await;
    match client.get_accounts().await {
        Ok(accounts) => Ok(Json(json!({ "connected": true, "accounts": accounts }))),
        Err(e) => Ok(Json(
            json!({ "connected": false, "accounts": [], "error": e.to_string() }),
        )),
    }
}

#[derive(Debug, Deserialize)]
pub struct CandlesQuery {
    pub symbol: String,
    pub start: Option<String>,
    pub end: Option<String>,
    pub interval: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CandlesResponse {
    pub symbol: String,
    pub symbol_id: i64,
    pub interval: String,
    pub start: String,
    pub end: String,
    pub candles: Vec<EquityCandle>,
}

pub async fn get_candles(
    State(state): State<AppState>,
    Query(params): Query<CandlesQuery>,
) -> AppResult<Json<CandlesResponse>> {
    let Some(qt) = state.questrade.as_ref() else {
        return Err(AppError::Internal("Questrade not configured".into()));
    };

    let year = Utc::now().format("%Y").to_string();
    let start = params.start.unwrap_or_else(|| format!("{}-01-01", year));
    let end = params
        .end
        .unwrap_or_else(|| Utc::now().format("%Y-%m-%d").to_string());
    let interval = params.interval.unwrap_or_else(|| "OneDay".to_string());

    let mut client = qt.lock().await;
    let symbol_id = client.search_symbol(&params.symbol).await.map_err(|e| {
        tracing::error!("Questrade symbol search failed: {}", e);
        e
    })?;
    let candles = client
        .get_candles(symbol_id, &start, &end, &interval)
        .await
        .map_err(|e| {
            tracing::error!(
                "Questrade get_candles failed (symbolId={}): {}",
                symbol_id,
                e
            );
            e
        })?;

    Ok(Json(CandlesResponse {
        symbol: params.symbol.to_uppercase(),
        symbol_id,
        interval,
        start,
        end,
        candles,
    }))
}
