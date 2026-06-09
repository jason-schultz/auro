use axum::extract::State;
use axum::Json;

use crate::brokers::wealthsimple::models::{UpsertWealthsimpleAccounts, WealthsimpleAccount};
use crate::error::AppResult;
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
