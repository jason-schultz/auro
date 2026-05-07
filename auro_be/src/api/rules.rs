//! HTTP endpoint for Opus to push rules into Rust's in-memory cache.
//!
//! Per Decision #22, this endpoint is internal — only Opus calls it. Vue/FE
//! never talks to it directly. (The future FE-facing rules endpoints live in
//! Opus, which writes to the DB and *then* calls this handler to activate.)
//!
//! Per Decision #23, this is the activation channel. The DB write in Opus is
//! the persistence channel. Both happen on every rule change; if either side
//! fails, the system tolerates it (DB-only push means rules don't take effect
//! until next push attempt; HTTP-only push means rules disappear on Rust
//! restart until Opus pushes again or recovery from DB runs).

use axum::extract::State;
use axum::Json;
use serde_json::{json, Value};

use crate::engine::rules::{Rules, RulesPayload};
use crate::error::AppResult;
use crate::state::AppState;

/// `POST /api/rules` — accepts a full rules payload from Opus and replaces the
/// in-memory cache atomically. Returns counts for observability.
///
/// Request body shape (see `engine::rules::RulesPayload`):
/// ```json
/// {
///   "rules": {
///     "<strategy-uuid>": {"enabled": true, "reason": "trending, ADX 32.4"},
///     ...
///   },
///   "computed_at": "2026-05-06T10:00:00Z"
/// }
/// ```
pub async fn push_rules(
    State(state): State<AppState>,
    Json(body): Json<RulesPayload>,
) -> AppResult<Json<Value>> {
    // Count how many strategies are enabled vs disabled in this payload, for observability.
    let (enabled_count, disabled_count) = Rules::count(&body);

    // Aquire the write lock and replace the entire rules state from the payload.
    {
        let mut rules = state.live.rules.write().await;
        rules.apply_payload(body);
    }

    Ok(Json(json!({
        "applied": true,
        "enabled": enabled_count,
        "disabled": disabled_count,
    })))
}
