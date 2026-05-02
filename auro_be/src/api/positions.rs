use axum::{Json, extract::{Path, State}};
use serde_json::{json, Value};

use crate::{error::AppResult, state::AppState};

pub async fn remove_in_memory_position(
    State(state): State<AppState>,
    Path(trade_id): Path<String>,
) -> AppResult<Json<Value>> {
    let removed_position = {
        let mut positions = state.live.open_positions.write().await;
        positions.remove(&trade_id)
    };

    match &removed_position {
        Some(pos) => {
            tracing::info!(
                "[POSITION REMOVED] trade_id={} instrument={} direction={:?} entry_price={} stop_loss_state={:?}",
                trade_id,
                pos.instrument,
                pos.direction,
                pos.entry_price,
                pos.stop_loss_state,
            );
        }
        None => {
            tracing::debug!(
                "[POSITION REMOVED] trade_id={} no-op (unknown trade_id)",
                trade_id,
            );
        }
    }

    Ok(Json(json!({ "removed": removed_position.is_some() })))
}