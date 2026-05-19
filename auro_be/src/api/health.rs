use axum::extract::State;
use axum::Json;
use serde_json::{json, Value};

use crate::state::AppState;

pub async fn health(State(state): State<AppState>) -> Json<Value> {
    let db_ok = sqlx::query("SELECT 1").execute(&state.db).await.is_ok();

    Json(json!({
        "status": if db_ok { "healthy" } else { "degraded" },
        "service": "auro",
        "database": if db_ok { "connected" } else { "disconnected" },
    }))
}

pub async fn live_health(State(state): State<AppState>) -> Json<Value> {
    let now = chrono::Utc::now();

    let engine_uptime_seconds = (now - state.start_time).num_seconds().max(0);

    let last_tick_seconds_ago = {
        let quotes = state.live.last_quotes.read().await;
        quotes
            .values()
            .map(|q| (now - q.at).num_seconds().max(0))
            .min()
    };

    let last_evaluator_run_seconds_ago = state
        .live
        .last_evaluator_run
        .read()
        .await
        .as_ref()
        .map(|t| (now - *t).num_seconds().max(0));

    let last_candle_persisted_seconds_ago = state
        .live
        .last_candle_persisted
        .read()
        .await
        .as_ref()
        .map(|t| (now - *t).num_seconds().max(0));

    let open_positions_count = state.live.open_positions.read().await.len();
    let instrument_metadata_loaded = !state.live.instrument_metadata.read().await.is_empty();
    let account_snapshot_age_seconds = state
        .live
        .account
        .read()
        .await
        .as_ref()
        .map(|s| (now - s.last_updated).num_seconds().max(0));

    Json(json!({
        "engine_uptime_seconds": engine_uptime_seconds,
        "last_tick_seconds_ago": last_tick_seconds_ago,
        "last_evaluator_run_seconds_ago": last_evaluator_run_seconds_ago,
        "last_candle_persisted_seconds_ago": last_candle_persisted_seconds_ago,
        "open_positions_count": open_positions_count,
        "instrument_metadata_loaded": instrument_metadata_loaded,
        "account_snapshot_age_seconds": account_snapshot_age_seconds,
    }))
}
