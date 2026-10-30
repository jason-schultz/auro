use axum::extract::State;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use std::future::Future;

use crate::engine::pipeline::{
    load_strategy_config, require_brokers, run_backtest, run_holdout, run_monte_carlo,
    run_parameter_stability, run_walk_forward, EvaluationResult,
};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

#[derive(Deserialize)]
pub struct PipelineRequest {
    pub strategy_config_id: Uuid,
}

pub async fn run_pipeline_backtest(
    State(state): State<AppState>,
    Json(req): Json<PipelineRequest>,
) -> AppResult<Json<Value>> {
    tracing::info!(
        "[Pipeline] Received backtest request for strategy_config_id {}",
        req.strategy_config_id
    );
    let (db, id) = (state.db.clone(), req.strategy_config_id);
    let result = detached(async move {
        let config = load_strategy_config(&db, id).await?;
        require_brokers(&db, &config).await?;
        run_backtest(&db, &config).await
    })
    .await?;
    Ok(Json(evaluation_response(
        "backtest",
        req.strategy_config_id,
        &result,
    )))
}

pub async fn run_pipeline_walk_forward(
    State(state): State<AppState>,
    Json(req): Json<PipelineRequest>,
) -> AppResult<Json<Value>> {
    tracing::info!(
        "[Pipeline] Received walk_forward request for strategy_config_id {}",
        req.strategy_config_id
    );
    let (db, id) = (state.db.clone(), req.strategy_config_id);
    let result = detached(async move {
        let config = load_strategy_config(&db, id).await?;
        require_brokers(&db, &config).await?;
        run_walk_forward(&db, &config).await
    })
    .await?;
    Ok(Json(evaluation_response(
        "walk_forward",
        req.strategy_config_id,
        &result,
    )))
}

pub async fn run_pipeline_monte_carlo(
    State(state): State<AppState>,
    Json(req): Json<PipelineRequest>,
) -> AppResult<Json<Value>> {
    tracing::info!(
        "[Pipeline] Received monte_carlo request for strategy_config_id {}",
        req.strategy_config_id
    );
    let (db, id) = (state.db.clone(), req.strategy_config_id);
    let result = detached(async move {
        let config = load_strategy_config(&db, id).await?;
        require_brokers(&db, &config).await?;
        run_monte_carlo(&db, &config).await
    })
    .await?;
    Ok(Json(evaluation_response(
        "monte_carlo",
        req.strategy_config_id,
        &result,
    )))
}

pub async fn run_pipeline_parameter_stability(
    State(state): State<AppState>,
    Json(req): Json<PipelineRequest>,
) -> AppResult<Json<Value>> {
    tracing::info!(
        "[Pipeline] Received parameter_stability request for strategy_config_id {}",
        req.strategy_config_id
    );
    let (db, id) = (state.db.clone(), req.strategy_config_id);
    let result = detached(async move {
        let config = load_strategy_config(&db, id).await?;
        require_brokers(&db, &config).await?;
        run_parameter_stability(&db, &config).await
    })
    .await?;
    Ok(Json(evaluation_response(
        "parameter_stability",
        req.strategy_config_id,
        &result,
    )))
}

pub async fn run_pipeline_holdout(
    State(state): State<AppState>,
    Json(req): Json<PipelineRequest>,
) -> AppResult<Json<Value>> {
    tracing::info!(
        "[Pipeline] Received holdout request for strategy_config_id {}",
        req.strategy_config_id
    );
    let (db, id) = (state.db.clone(), req.strategy_config_id);
    let result = detached(async move {
        let config = load_strategy_config(&db, id).await?;
        require_brokers(&db, &config).await?;
        run_holdout(&db, &config).await
    })
    .await?;
    Ok(Json(evaluation_response(
        "holdout",
        req.strategy_config_id,
        &result,
    )))
}

/// Runs a stage on its own task, so a caller that hangs up part-way (Opus
/// timing out, or restarting) doesn't cancel it and leave its row
/// "running": the stage finishes and records its result either way. A
/// tester that stops mid-stage still leaves one; Opus reads that as stuck
/// (`Opus.Pipeline.Stuck`).
async fn detached<F>(stage: F) -> AppResult<EvaluationResult>
where
    F: Future<Output = AppResult<EvaluationResult>> + Send + 'static,
{
    tokio::spawn(stage)
        .await
        .map_err(|e| AppError::Internal(format!("pipeline stage task ended early: {e}")))?
}

fn evaluation_response(stage: &str, config_id: Uuid, result: &EvaluationResult) -> Value {
    json!({
        "strategy_config_id": config_id,
        "evaluation_id":      result.evaluation_id,
        "stage":              stage,
        "status":             result.status,
        "stats":              result.stats,
        "failure_reason":     result.failure_reason,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    #[tokio::test]
    async fn a_stage_finishes_when_its_caller_hangs_up() {
        let finished = Arc::new(AtomicBool::new(false));
        let flag = finished.clone();
        let caller = tokio::spawn(detached(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            flag.store(true, Ordering::SeqCst);
            Err(AppError::Internal("stand-in stage".into()))
        }));

        // The caller gives up before the stage is done.
        tokio::time::sleep(Duration::from_millis(5)).await;
        caller.abort();

        tokio::time::sleep(Duration::from_millis(150)).await;
        assert!(finished.load(Ordering::SeqCst));
    }
}
