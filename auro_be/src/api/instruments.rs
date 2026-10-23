//! The security master's vendor-facing maintenance. Listing and editing
//! the master is Opus's page; Rust only fills in what a vendor has to be
//! asked for.

use axum::extract::State;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::brokers::questrade::identity;
use crate::error::{AppError, AppResult};
use crate::state::AppState;

#[derive(Debug, Default, Deserialize)]
pub struct EnrichParams {
    /// Re-query listings that already have a Questrade id (refreshes the
    /// exchange and currency they report).
    #[serde(default)]
    pub all: bool,
}

/// Ask Questrade who each listing with a Questrade spelling is, and record
/// its symbol id, exchange and currency. One search plus one detail call per
/// listing, inside the rate limit for the few hundred rows the master holds.
pub async fn enrich(
    State(state): State<AppState>,
    body: Option<Json<EnrichParams>>,
) -> AppResult<Json<Value>> {
    let Some(qt) = state.questrade.as_ref() else {
        return Err(AppError::Internal("Questrade not configured".into()));
    };
    let params = body.map(|Json(p)| p).unwrap_or_default();
    let mut client = qt.lock().await;
    let report = identity::enrich(&mut client, &state.db, params.all).await?;
    drop(client);
    tracing::info!(
        "Instrument enrich: {} resolved, {} failed",
        report.resolved,
        report.failed.len()
    );
    Ok(Json(json!({
        "resolved": report.resolved,
        "failed": report.failed,
    })))
}
