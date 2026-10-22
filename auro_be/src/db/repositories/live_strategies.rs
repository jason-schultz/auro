use chrono::{DateTime, Utc};
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::engine::types::LiveStrategy;

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct LiveStrategyListRow {
    pub id: Uuid,
    pub strategy_type: String,
    pub instrument: String,
    pub granularity: String,
    pub parameters: Value,
    pub enabled: bool,
    pub curator_mode: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct PipelineStrategyStatsRow {
    pub id: Uuid,
    pub source: String,
    pub score: Option<f64>,
    pub bt_stats: Option<Value>,
    pub wf_stats: Option<Value>,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct LatestKfoldStatsRow {
    pub live_strategy_id: Uuid,
    pub fold_count: i32,
    pub pass_count: i32,
    pub pass_rate: f64,
    pub median_sharpe: f64,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct LiveStrategyDetailRow {
    pub id: Uuid,
    pub strategy_type: String,
    pub instrument: String,
    pub granularity: String,
    pub parameters: Value,
    pub enabled: bool,
    pub curator_mode: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct ToggledStrategyRow {
    pub enabled: bool,
    pub curator_mode: String,
    pub strategy_type: String,
    pub instrument: String,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct TradingConfigRow {
    pub key: String,
    pub value: Value,
}

pub(crate) async fn list_live_strategies(
    pool: &PgPool,
) -> Result<Vec<LiveStrategyListRow>, sqlx::Error> {
    sqlx::query_as(
        r#"
        SELECT id, strategy_type, instrument, granularity, parameters,
             enabled, curator_mode, created_at, updated_at
        FROM live_strategies
        ORDER BY instrument, strategy_type
        "#,
    )
    .fetch_all(pool)
    .await
}

pub(crate) async fn fetch_pipeline_strategy_stats(
    pool: &PgPool,
    strategy_ids: &[Uuid],
) -> Result<Vec<PipelineStrategyStatsRow>, sqlx::Error> {
    if strategy_ids.is_empty() {
        return Ok(Vec::new());
    }

    sqlx::query_as(
        r#"
        SELECT DISTINCT ON (ls.id)
            ls.id,
            sc.source,
            sc.score,
            bt.stats  AS bt_stats,
            wf.stats  AS wf_stats
        FROM live_strategies ls
        JOIN strategy_configs sc
            ON  sc.instrument    = ls.instrument
            AND sc.strategy_type = ls.strategy_type
            AND sc.parameters    = ls.parameters
        LEFT JOIN strategy_evaluations bt
            ON  bt.strategy_config_id = sc.id
            AND bt.stage   = 'backtest'
            AND bt.status  = 'passed'
        LEFT JOIN strategy_evaluations wf
            ON  wf.strategy_config_id = sc.id
            AND wf.stage   = 'walk_forward'
            AND wf.status  = 'passed'
        WHERE ls.id = ANY($1)
        ORDER BY ls.id, sc.score DESC NULLS LAST
        "#,
    )
    .bind(strategy_ids)
    .fetch_all(pool)
    .await
}

pub(crate) async fn fetch_latest_kfold_stats(
    pool: &PgPool,
    strategy_ids: &[Uuid],
) -> Result<Vec<LatestKfoldStatsRow>, sqlx::Error> {
    if strategy_ids.is_empty() {
        return Ok(Vec::new());
    }

    sqlx::query_as(
        r#"
        SELECT DISTINCT ON (live_strategy_id)
            live_strategy_id,
            fold_count,
            (pass_rate * fold_count)::int AS pass_count,
            pass_rate,
            median_sharpe
        FROM kfold_validations
        WHERE live_strategy_id = ANY($1)
        ORDER BY live_strategy_id, validated_at DESC
        "#,
    )
    .bind(strategy_ids)
    .fetch_all(pool)
    .await
}

pub(crate) async fn insert_live_strategy(
    pool: &PgPool,
    id: Uuid,
    strategy_type: &str,
    instrument: &str,
    granularity: &str,
    parameters: &Value,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        r#"
        INSERT INTO live_strategies (id, strategy_type, instrument, granularity, parameters, enabled)
        VALUES ($1, $2, $3, $4, $5, false)
        "#,
    )
    .bind(id)
    .bind(strategy_type)
    .bind(instrument)
    .bind(granularity)
    .bind(parameters)
    .execute(pool)
    .await?;

    Ok(())
}

pub(crate) async fn get_live_strategy_by_id(
    pool: &PgPool,
    id: Uuid,
) -> Result<Option<LiveStrategyDetailRow>, sqlx::Error> {
    sqlx::query_as(
        "SELECT id, strategy_type, instrument, granularity, parameters, enabled, curator_mode, created_at, updated_at FROM live_strategies WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
}

pub(crate) async fn update_live_strategy(
    pool: &PgPool,
    id: Uuid,
    strategy_type: &str,
    instrument: &str,
    granularity: &str,
    parameters: &Value,
) -> Result<u64, sqlx::Error> {
    let result = sqlx::query(
        r#"
        UPDATE live_strategies
        SET strategy_type = $1, instrument = $2, granularity = $3, parameters = $4,
            updated_at = NOW()
        WHERE id = $5
        "#,
    )
    .bind(strategy_type)
    .bind(instrument)
    .bind(granularity)
    .bind(parameters)
    .bind(id)
    .execute(pool)
    .await?;

    Ok(result.rows_affected())
}

pub(crate) async fn toggle_live_strategy(
    pool: &PgPool,
    id: Uuid,
) -> Result<Option<ToggledStrategyRow>, sqlx::Error> {
    sqlx::query_as(
        "UPDATE live_strategies
         SET enabled = NOT enabled,
             curator_mode = CASE WHEN enabled THEN 'pinned_off' ELSE 'pinned_on' END,
             updated_at = NOW()
         WHERE id = $1
         RETURNING enabled, curator_mode, strategy_type, instrument",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
}

pub(crate) async fn set_live_strategy_curator_auto(
    pool: &PgPool,
    id: Uuid,
) -> Result<Option<ToggledStrategyRow>, sqlx::Error> {
    sqlx::query_as(
        "UPDATE live_strategies
         SET curator_mode = 'auto',
             updated_at = NOW()
         WHERE id = $1
         RETURNING enabled, curator_mode, strategy_type, instrument",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
}

pub(crate) async fn delete_live_strategy_returning_instrument(
    pool: &PgPool,
    id: Uuid,
) -> Result<Option<String>, sqlx::Error> {
    let row: Option<(String,)> =
        sqlx::query_as("DELETE FROM live_strategies WHERE id = $1 RETURNING instrument")
            .bind(id)
            .fetch_optional(pool)
            .await?;

    Ok(row.map(|(instrument,)| instrument))
}

pub(crate) async fn list_trading_config(
    pool: &PgPool,
) -> Result<Vec<TradingConfigRow>, sqlx::Error> {
    sqlx::query_as("SELECT key, value FROM trading_config ORDER BY key")
        .fetch_all(pool)
        .await
}

pub(crate) async fn upsert_trading_config(
    pool: &PgPool,
    key: &str,
    value: &Value,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO trading_config (key, value, updated_at) VALUES ($1, $2, NOW()) ON CONFLICT (key) DO UPDATE SET value = $2, updated_at = NOW()",
    )
    .bind(key)
    .bind(value)
    .execute(pool)
    .await?;

    Ok(())
}

/// Every live strategy on a key, enabled or not. The evaluator needs the
/// disabled ones too: their open positions must still be managed to exit.
pub(crate) async fn list_for_instrument_granularity(
    pool: &PgPool,
    instrument: &str,
    granularity: &str,
) -> Result<Vec<LiveStrategy>, sqlx::Error> {
    sqlx::query_as(
        "SELECT id, strategy_type, instrument, granularity, parameters, enabled \
         FROM live_strategies WHERE instrument = $1 AND granularity = $2",
    )
    .bind(instrument)
    .bind(granularity)
    .fetch_all(pool)
    .await
}
