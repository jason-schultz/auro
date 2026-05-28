use serde_json::Value;
use sqlx::PgPool;
use std::collections::HashMap;
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
    // Load all candidate rows matching this stage/timeframe at any specificity
    // level along instrument_class and strategy_type. Then resolve per-metric
    // to the most specific applicable rule.
    let rows: Vec<(String, String, f64, String, String)> = sqlx::query_as(
        "SELECT metric, operator, value, instrument_class, strategy_type
         FROM validation_thresholds
         WHERE stage = $1 AND timeframe_class = $2
           AND instrument_class IN ($3, 'all')
           AND strategy_type IN ($4, 'all')",
    )
    .bind(stage)
    .bind(timeframe_class)
    .bind(instrument_class)
    .bind(strategy_type)
    .fetch_all(pool)
    .await?;

    // Specificity score: higher = more specific. Per metric, keep highest.
    let mut best: HashMap<String, (i32, ValidationThresholdRow)> = HashMap::new();
    for (metric, operator, value, ic, st) in rows {
        let specificity = (if ic == instrument_class { 2 } else { 0 })
            + (if st == strategy_type { 1 } else { 0 });
        let entry = best.entry(metric.clone()).or_insert((
            -1,
            ValidationThresholdRow {
                metric: metric.clone(),
                operator: operator.clone(),
                value,
            },
        ));
        if specificity > entry.0 {
            *entry = (
                specificity,
                ValidationThresholdRow {
                    metric,
                    operator,
                    value,
                },
            );
        }
    }
    Ok(best.into_values().map(|(_, row)| row).collect())
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
