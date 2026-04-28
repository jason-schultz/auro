use axum::extract::{Path, State};
use axum::Json;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::error::{AppError, AppResult};
use crate::state::AppState;

#[derive(Deserialize)]
pub struct EvaluateRequest {
    pub target_slot: DateTime<Utc>,
    pub idempotency_key: String,
}

#[derive(Serialize)]
pub struct EvaluateResponse {
    pub evaluated: bool,
    pub target_slot: DateTime<Utc>,
    pub data_slot: Option<DateTime<Utc>>,
    pub staleness_candles: u32,
    pub duplicate: bool,
    pub signals: Vec<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

pub async fn evaluate(
    Path(granularity): Path<String>,
    State(state): State<AppState>,
    Json(body): Json<EvaluateRequest>,
) -> AppResult<Json<EvaluateResponse>> {
    Ok(Json(EvaluateResponse {
        evaluated: false,
        target_slot: body.target_slot,
        data_slot: None,
        staleness_candles: 0,
        duplicate: false,
        signals: vec![],
        reason: Some("not_implemented".to_string()),
    }))
}
