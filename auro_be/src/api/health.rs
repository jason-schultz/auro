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
