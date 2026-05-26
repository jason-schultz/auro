use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct StrategyConfigRow {
    pub instrument: String,
    pub granularity: String,
    pub strategy_type: String,
    pub parameters: Value,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct ValidationThresholdRow {
    pub metric: String,
    pub operator: String,
    pub value: f64,
}

pub(crate) async fn find_strategy_config(
    pool: &PgPool,
    config_id: Uuid,
) -> Result<Option<StrategyConfigRow>, sqlx::Error> {
    sqlx::query_as(
        "SELECT instrument, granularity, strategy_type, parameters FROM strategy_configs WHERE id = $1",
    )
    .bind(config_id)
    .fetch_optional(pool)
    .await
}

pub(crate) async fn load_validation_thresholds(
    pool: &PgPool,
    stage: &str,
    timeframe_class: &str,
    instrument_class: &str,
    strategy_type: &str,
) -> Result<Vec<ValidationThresholdRow>, sqlx::Error> {
    // Level 1: instrument_class + strategy_type specific.
    let rows: Vec<ValidationThresholdRow> = sqlx::query_as(
        "SELECT metric, operator, value FROM validation_thresholds \
         WHERE stage = $1 AND timeframe_class = $2 AND instrument_class = $3 AND strategy_type = $4",
    )
    .bind(stage)
    .bind(timeframe_class)
    .bind(instrument_class)
    .bind(strategy_type)
    .fetch_all(pool)
    .await?;

    if !rows.is_empty() {
        return Ok(rows);
    }

    // Level 2: instrument_class + strategy_type='all'.
    let rows: Vec<ValidationThresholdRow> = sqlx::query_as(
        "SELECT metric, operator, value FROM validation_thresholds \
         WHERE stage = $1 AND timeframe_class = $2 AND instrument_class = $3 AND strategy_type = 'all'",
    )
    .bind(stage)
    .bind(timeframe_class)
    .bind(instrument_class)
    .fetch_all(pool)
    .await?;

    if !rows.is_empty() {
        return Ok(rows);
    }

    // Level 3: catch-all (instrument_class='all', strategy_type='all').
    sqlx::query_as(
        "SELECT metric, operator, value FROM validation_thresholds \
         WHERE stage = $1 AND timeframe_class = $2 AND instrument_class = 'all' AND strategy_type = 'all'",
    )
    .bind(stage)
    .bind(timeframe_class)
    .fetch_all(pool)
    .await
}

pub(crate) async fn upsert_evaluation_running(
    pool: &PgPool,
    config_id: Uuid,
    stage: &str,
) -> Result<Uuid, sqlx::Error> {
    let row = sqlx::query_scalar!(
        r#"
        INSERT INTO strategy_evaluations (id, strategy_config_id, stage, status, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, 'running', NOW(), NOW())
        ON CONFLICT (strategy_config_id, stage)
        DO UPDATE SET status = 'running', stats = NULL, failure_reason = NULL, evaluated_at = NULL, updated_at = NOW()
        RETURNING id
        "#,
        config_id,
        stage,
    )
    .fetch_one(pool)
    .await?;

    Ok(row)
}

pub(crate) async fn finalize_evaluation(
    pool: &PgPool,
    evaluation_id: Uuid,
    status: &str,
    stats: &Value,
    failure_reason: Option<&str>,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        r#"
        UPDATE strategy_evaluations
        SET status = $1, stats = $2, failure_reason = $3, evaluated_at = NOW(), updated_at = NOW()
        WHERE id = $4
        "#,
    )
    .bind(status)
    .bind(stats)
    .bind(failure_reason)
    .bind(evaluation_id)
    .execute(pool)
    .await?;

    Ok(())
}
