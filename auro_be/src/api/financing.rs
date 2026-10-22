//! Financing-rate snapshots. Opus's FinancingSnapshotWorker calls this once a
//! day before the 17:00 New York rollover; the backtest uses the recorded
//! rates in preference to the policy-rate model (see `engine::financing`).

use axum::extract::State;
use axum::Json;
use chrono::Utc;
use chrono_tz::America::New_York;
use serde_json::{json, Value};

use crate::db::repositories::financing as financing_repo;
use crate::error::AppResult;
use crate::state::AppState;

/// Record today's OANDA financing rates for every instrument the account can
/// trade. `as_of` is the New York date, i.e. the rollover the rates apply to.
pub async fn snapshot(State(state): State<AppState>) -> AppResult<Json<Value>> {
    let instruments = state.oanda.get_instruments().await?;
    let as_of = Utc::now().with_timezone(&New_York).date_naive();

    let rates: Vec<(String, f64, f64)> = instruments
        .iter()
        .filter_map(|i| {
            i.financing
                .as_ref()
                .map(|f| (i.name.clone(), f.long_rate, f.short_rate))
        })
        .collect();

    let stored = financing_repo::upsert_instrument_financing(&state.db, as_of, &rates).await?;

    tracing::info!(
        "Recorded OANDA financing rates for {} instruments ({})",
        stored,
        as_of
    );

    Ok(Json(json!({
        "as_of": as_of,
        "instruments": stored,
        "without_rates": instruments.len() - stored,
    })))
}
