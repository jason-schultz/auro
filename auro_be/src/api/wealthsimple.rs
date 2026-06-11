use std::collections::HashMap;

use axum::extract::State;
use axum::Json;
use serde_json::{json, Value};

use crate::brokers::wealthsimple::models::{UpsertWealthsimpleAccounts, WealthsimpleAccount};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

pub async fn get_accounts(
    State(state): State<AppState>,
) -> AppResult<Json<Vec<WealthsimpleAccount>>> {
    let accounts = state.wealthsimple.list_accounts().await?;
    Ok(Json(accounts))
}

pub async fn save_accounts(
    State(state): State<AppState>,
    Json(body): Json<UpsertWealthsimpleAccounts>,
) -> AppResult<Json<Vec<WealthsimpleAccount>>> {
    state.wealthsimple.save_accounts(&body.accounts).await?;
    let updated = state.wealthsimple.list_accounts().await?;
    Ok(Json(updated))
}

pub async fn refresh_prices(State(state): State<AppState>) -> AppResult<Json<Value>> {
    let Some(qt) = state.questrade.as_ref() else {
        return Err(AppError::Internal("Questrade not configured".into()));
    };

    // Load all positions
    let accounts = state.wealthsimple.list_accounts().await?;
    let positions: Vec<_> = accounts.iter().flat_map(|a| a.positions.iter()).collect();

    if positions.is_empty() {
        return Ok(Json(json!({ "updated": 0 })));
    }

    let mut client = qt.lock().await;

    // Resolve unique symbols → symbol IDs
    let mut symbol_to_id: HashMap<String, i64> = HashMap::new();
    for pos in &positions {
        let sym = pos.symbol.to_uppercase();
        if !symbol_to_id.contains_key(&sym) {
            match client.search_symbol(&sym).await {
                Ok(id) => {
                    symbol_to_id.insert(sym, id);
                }
                Err(e) => {
                    tracing::warn!("Could not resolve symbol {}: {}", pos.symbol, e);
                }
            }
        }
    }

    if symbol_to_id.is_empty() {
        return Ok(Json(json!({ "updated": 0 })));
    }

    // Batch-fetch quotes
    let ids: Vec<i64> = symbol_to_id.values().copied().collect();
    let quotes = client.get_quotes(&ids).await?;
    drop(client); // release mutex before DB work

    // Build symbol_id → last price map
    let id_to_price: HashMap<i64, f64> = quotes
        .into_iter()
        .filter_map(|q| q.last_trade_price.map(|p| (q.symbol_id, p)))
        .collect();

    // Build (position_id, price) update list
    let updates: Vec<(i32, f64)> = positions
        .iter()
        .filter_map(|pos| {
            let sym = pos.symbol.to_uppercase();
            let id = symbol_to_id.get(&sym)?;
            let price = id_to_price.get(id)?;
            Some((pos.id, *price))
        })
        .collect();

    let count = updates.len();
    state.wealthsimple.update_position_prices(&updates).await?;

    tracing::info!("Refreshed prices for {} Wealthsimple positions", count);
    Ok(Json(json!({ "updated": count })))
}
