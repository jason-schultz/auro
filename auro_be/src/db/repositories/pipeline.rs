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
    // A most-specific row with operator `off` takes that metric out of the
    // judging for its class (owned shares' fixed drawdown cap: they're
    // judged against just holding instead).
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
    Ok(best
        .into_values()
        .map(|(_, row)| row)
        .filter(|row| row.operator != "off")
        .collect())
}

pub(crate) async fn upsert_evaluation_running(
    pool: &PgPool,
    config_id: Uuid,
    stage: &str,
) -> Result<Uuid, sqlx::Error> {
    sqlx::query_scalar(
        r#"
        INSERT INTO strategy_evaluations (id, strategy_config_id, stage, status, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, 'running', NOW(), NOW())
        ON CONFLICT (strategy_config_id, stage)
        DO UPDATE SET status = 'running', stats = NULL, failure_reason = NULL, evaluated_at = NULL,
                      rules_version = NULL, updated_at = NOW()
        RETURNING id
        "#,
    )
    .bind(config_id)
    .bind(stage)
    .fetch_one(pool)
    .await
}

pub(crate) async fn finalize_evaluation(
    pool: &PgPool,
    evaluation_id: Uuid,
    status: &str,
    stats: &Value,
    failure_reason: Option<&str>,
    rules_version: i32,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        r#"
        UPDATE strategy_evaluations
        SET status = $1, stats = $2, failure_reason = $3, rules_version = $4,
            evaluated_at = NOW(), updated_at = NOW()
        WHERE id = $5
        "#,
    )
    .bind(status)
    .bind(stats)
    .bind(failure_reason)
    .bind(rules_version)
    .bind(evaluation_id)
    .execute(pool)
    .await?;

    Ok(())
}

/// A config that has looked at the sealed window (`holdout_look_configs`).
#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct HoldoutLook {
    pub strategy_type: String,
    pub granularity: String,
    pub parameters: Value,
}

/// Every config on this market (`instrument` alone, or a basket's
/// `basket_markets`; its `instrument` is its first market) that has had a
/// holdout evaluation on the window starting `holdout_start` (ISO date),
/// including any in progress (no stats yet). Every look at the sealed
/// window weakens what a pass there proves (`pipeline::holdout_looks`
/// counts the distinct ones).
pub(crate) async fn holdout_look_configs(
    pool: &PgPool,
    instrument: &str,
    basket_markets: Option<&[String]>,
    holdout_start: &str,
) -> Result<Vec<HoldoutLook>, sqlx::Error> {
    sqlx::query_as(
        "SELECT c.strategy_type, c.granularity, c.parameters \
         FROM strategy_evaluations e \
         JOIN strategy_configs c ON c.id = e.strategy_config_id \
         WHERE e.stage = 'holdout' AND c.instrument = $1 \
           AND c.parameters->'basket'->'markets' IS NOT DISTINCT FROM $2 \
           AND (e.stats IS NULL OR e.stats->>'holdout_start' IS NULL \
                OR e.stats->>'holdout_start' = $3)",
    )
    .bind(instrument)
    .bind(basket_markets.map(|m| serde_json::json!(m)))
    .bind(holdout_start)
    .fetch_all(pool)
    .await
}

/// One pipeline try for the deflated Sharpe: a config with a finished
/// backtest (passed or failed, with a Sharpe), archived ones included.
#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct BacktestTry {
    pub strategy_type: String,
    pub parameters: Value,
    pub instrument: String,
    pub granularity: String,
    /// The backtest's per-trade Sharpe (a ranked basket's: its months').
    pub sharpe: f64,
    /// What that Sharpe was measured over: its trade count, or a ranked
    /// basket's months (`judged_on: months`). 0 when not recorded.
    pub periods: i64,
}

pub(crate) async fn list_backtest_tries(pool: &PgPool) -> Result<Vec<BacktestTry>, sqlx::Error> {
    sqlx::query_as(
        "SELECT c.strategy_type, c.parameters, c.instrument, c.granularity, \
                (e.stats->>'sharpe')::FLOAT8 AS sharpe, \
                COALESCE(CASE WHEN e.stats->>'judged_on' = 'months' \
                              THEN (e.stats->>'num_months')::BIGINT \
                              ELSE (e.stats->>'num_trades')::BIGINT END, 0) AS periods \
         FROM strategy_evaluations e \
         JOIN strategy_configs c ON c.id = e.strategy_config_id \
         WHERE e.stage = 'backtest' AND e.status IN ('passed', 'failed') \
           AND jsonb_typeof(e.stats->'sharpe') = 'number'",
    )
    .fetch_all(pool)
    .await
}

/// The markets ("INSTRUMENT@GRANULARITY") research tried an idea on
/// outside the pipeline (`research_trials`), each once.
pub(crate) async fn list_research_markets(
    pool: &PgPool,
    family: &str,
) -> Result<Vec<String>, sqlx::Error> {
    sqlx::query_scalar(
        "SELECT DISTINCT market FROM research_trials, unnest(markets) AS market \
         WHERE family = $1 ORDER BY market",
    )
    .bind(family)
    .fetch_all(pool)
    .await
}
