use axum::extract::State;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::engine::pipeline::{load_strategy_config, run_backtest, run_monte_carlo, run_walk_forward};
use crate::error::AppResult;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct PipelineRequest {
    pub strategy_config_id: Uuid,
}

pub async fn run_pipeline_backtest(
    State(state): State<AppState>,
    Json(req): Json<PipelineRequest>,
) -> AppResult<Json<Value>> {
    tracing::info!("[Pipeline] Received backtest request for strategy_config_id {}", req.strategy_config_id);
    let config = load_strategy_config(&state.db, req.strategy_config_id).await?;
    let result = run_backtest(&state.db, &config).await?;
    Ok(Json(evaluation_response("backtest", req.strategy_config_id, &result)))
}

pub async fn run_pipeline_walk_forward(
    State(state): State<AppState>,
    Json(req): Json<PipelineRequest>,
) -> AppResult<Json<Value>> {
    tracing::info!("[Pipeline] Received walk_forward request for strategy_config_id {}", req.strategy_config_id);
    let config = load_strategy_config(&state.db, req.strategy_config_id).await?;
    let result = run_walk_forward(&state.db, &config).await?;
    Ok(Json(evaluation_response("walk_forward", req.strategy_config_id, &result)))
}

pub async fn run_pipeline_monte_carlo(
    State(state): State<AppState>,
    Json(req): Json<PipelineRequest>,
) -> AppResult<Json<Value>> {
    tracing::info!("[Pipeline] Received monte_carlo request for strategy_config_id {}", req.strategy_config_id);
    let config = load_strategy_config(&state.db, req.strategy_config_id).await?;
    let result = run_monte_carlo(&state.db, &config).await?;
    Ok(Json(evaluation_response("monte_carlo", req.strategy_config_id, &result)))
}

fn evaluation_response(
    stage: &str,
    config_id: Uuid,
    result: &crate::engine::pipeline::EvaluationResult,
) -> Value {
    json!({
        "strategy_config_id": config_id,
        "evaluation_id":      result.evaluation_id,
        "stage":              stage,
        "status":             result.status,
        "stats":              result.stats,
        "failure_reason":     result.failure_reason,
    })
}
