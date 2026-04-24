use axum::extract::{Path, State};
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

use crate::error::AppResult;
use crate::state::AppState;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Strategy {
    pub id: Uuid,
    pub name: String,
    pub instrument: String,
    pub granularity: String,
    pub enabled: bool,
    pub config: StrategyConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StrategyConfig {
    pub entry_rules: Vec<Rule>,
    pub exit_rules: Vec<Rule>,
    pub stop_loss_pips: Option<f64>,
    pub take_profit_pips: Option<f64>,
    pub position_size: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Rule {
    pub indicator: String,
    pub params: Value,
    pub condition: String,
    pub value: Value,
}

#[derive(Debug, Deserialize)]
pub struct CreateStrategy {
    pub name: String,
    pub instrument: String,
    pub granularity: String,
    pub config: StrategyConfig,
}

pub async fn list_strategies(State(state): State<AppState>) -> AppResult<Json<Value>> {
    let rows = sqlx::query_as::<_, (Uuid, String, String, String, bool, Value)>(
        "SELECT id, name, instrument, granularity, enabled, config FROM strategies ORDER BY name",
    )
    .fetch_all(&state.db)
    .await
    .map_err(crate::error::AppError::Database)?;

    let strategies: Vec<Value> = rows
        .iter()
        .map(|(id, name, instrument, granularity, enabled, config)| {
            json!({
                "id": id,
                "name": name,
                "instrument": instrument,
                "granularity": granularity,
                "enabled": enabled,
                "config": config,
            })
        })
        .collect();

    Ok(Json(json!({ "strategies": strategies })))
}

pub async fn create_strategy(
    State(state): State<AppState>,
    Json(payload): Json<CreateStrategy>,
) -> AppResult<Json<Value>> {
    let id = Uuid::new_v4();
    let config_json = serde_json::to_value(&payload.config)
        .map_err(|e| crate::error::AppError::BadRequest(e.to_string()))?;

    sqlx::query(
        "INSERT INTO strategies (id, name, instrument, granularity, enabled, config) VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(id)
    .bind(&payload.name)
    .bind(&payload.instrument)
    .bind(&payload.granularity)
    .bind(false)
    .bind(&config_json)
    .execute(&state.db)
    .await
    .map_err(crate::error::AppError::Database)?;

    Ok(Json(json!({
        "id": id,
        "name": payload.name,
        "instrument": payload.instrument,
        "granularity": payload.granularity,
        "enabled": false,
        "config": config_json,
    })))
}

pub async fn get_strategy(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let row = sqlx::query_as::<_, (Uuid, String, String, String, bool, Value)>(
        "SELECT id, name, instrument, granularity, enabled, config FROM strategies WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(&state.db)
    .await
    .map_err(crate::error::AppError::Database)?;

    match row {
        Some((id, name, instrument, granularity, enabled, config)) => {
            Ok(Json(json!({
                "id": id,
                "name": name,
                "instrument": instrument,
                "granularity": granularity,
                "enabled": enabled,
                "config": config,
            })))
        }
        None => Err(crate::error::AppError::NotFound("Strategy not found".into())),
    }
}

pub async fn update_strategy(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(payload): Json<CreateStrategy>,
) -> AppResult<Json<Value>> {
    let config_json = serde_json::to_value(&payload.config)
        .map_err(|e| crate::error::AppError::BadRequest(e.to_string()))?;

    let result = sqlx::query(
        "UPDATE strategies SET name = $1, instrument = $2, granularity = $3, config = $4 WHERE id = $5",
    )
    .bind(&payload.name)
    .bind(&payload.instrument)
    .bind(&payload.granularity)
    .bind(&config_json)
    .bind(id)
    .execute(&state.db)
    .await
    .map_err(crate::error::AppError::Database)?;

    if result.rows_affected() == 0 {
        return Err(crate::error::AppError::NotFound("Strategy not found".into()));
    }

    Ok(Json(json!({
        "id": id,
        "name": payload.name,
        "instrument": payload.instrument,
        "granularity": payload.granularity,
        "config": config_json,
    })))
}

pub async fn toggle_strategy(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let row = sqlx::query_as::<_, (bool,)>(
        "UPDATE strategies SET enabled = NOT enabled WHERE id = $1 RETURNING enabled",
    )
    .bind(id)
    .fetch_optional(&state.db)
    .await
    .map_err(crate::error::AppError::Database)?;

    match row {
        Some((enabled,)) => Ok(Json(json!({ "id": id, "enabled": enabled }))),
        None => Err(crate::error::AppError::NotFound("Strategy not found".into())),
    }
}

pub async fn delete_strategy(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let result = sqlx::query("DELETE FROM strategies WHERE id = $1")
        .bind(id)
        .execute(&state.db)
        .await
        .map_err(crate::error::AppError::Database)?;

    if result.rows_affected() == 0 {
        return Err(crate::error::AppError::NotFound("Strategy not found".into()));
    }

    Ok(Json(json!({ "deleted": true })))
}