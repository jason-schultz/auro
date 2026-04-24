use axum::extract::{Query, State};
use axum::Json;
use serde_json::{json, Value};

use crate::error::AppResult;
use crate::state::AppState;

#[derive(serde::Deserialize)]
pub struct PricingParams {
    pub instruments: String,
}

pub async fn get_account(State(state): State<AppState>) -> AppResult<Json<Value>> {
    let account = state.oanda.get_account().await?;

    Ok(Json(json!({
        "id": account.id,
        "currency": account.currency,
        "balance": account.balance,
        "unrealized_pl": account.unrealized_pl,
        "pl": account.pl,
        "open_trade_count": account.open_trade_count,
        "open_position_count": account.open_position_count,
        "margin_used": account.margin_used,
        "margin_available": account.margin_available,
    })))
}

pub async fn get_instruments(State(state): State<AppState>) -> AppResult<Json<Value>> {
    let instruments = state.oanda.get_instruments().await?;

    Ok(Json(json!({
        "instruments": instruments,
        "count": instruments.len(),
    })))
}

pub async fn get_pricing(
    State(state): State<AppState>,
    Query(params): Query<PricingParams>,
) -> AppResult<Json<Value>> {
    let instruments: Vec<&str> = params.instruments.split(',').collect();
    let prices = state.oanda.get_pricing(&instruments).await?;

    Ok(Json(json!({
        "prices": prices,
    })))
}

pub async fn get_open_trades(State(state): State<AppState>) -> AppResult<Json<Value>> {
    let resp = state.oanda.get_open_trades().await?;
    Ok(Json(resp))
}
