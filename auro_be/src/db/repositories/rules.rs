use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

/// All persisted rules. `rules.computed_at` is a naive UTC `TIMESTAMP`
/// (Opus-owned), so it is converted to `TIMESTAMPTZ` for decoding.
pub(crate) async fn load_rules(
    pool: &PgPool,
) -> Result<Vec<(Uuid, bool, Option<String>, DateTime<Utc>)>, sqlx::Error> {
    sqlx::query_as(
        "SELECT live_strategy_id, enabled, reason, computed_at AT TIME ZONE 'UTC' FROM rules",
    )
    .fetch_all(pool)
    .await
}
