use chrono::{DateTime, Utc};
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use super::instruments as instruments_repo;
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

/// An assignment's full strategy JSON (`engine::strategy::Strategy`): its
/// recipe (`strategies.definition`) plus the assignment's instrument,
/// timeframe and sizing. Needs `live_strategies ls JOIN strategies s`.
/// research/strategy_assignments_plan.md has the split.
pub(crate) const PARAMETERS_SQL: &str = "(s.definition \
    || jsonb_build_object('instrument', ls.instrument, 'granularity', s.granularity) \
    || CASE WHEN ls.sizing IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('sizing', ls.sizing) END)";

pub(crate) async fn list_live_strategies(
    pool: &PgPool,
) -> Result<Vec<LiveStrategyListRow>, sqlx::Error> {
    sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT ls.id, ls.strategy_type, ls.instrument, ls.granularity, {PARAMETERS_SQL} AS parameters, \
             ls.enabled, ls.curator_mode, ls.created_at, ls.updated_at \
         FROM live_strategies ls JOIN strategies s ON s.id = ls.strategy_id \
         ORDER BY ls.instrument, ls.strategy_type"
    )))
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
    sqlx::query(sqlx::AssertSqlSafe(format!(
        "INSERT INTO live_strategies \
            (id, strategy_type, instrument, instrument_id, granularity, parameters, enabled) \
         VALUES ($1, $2, $3, {}, $4, $5, false)",
        instruments_repo::id_for_name_sql("$3")
    )))
    .bind(id)
    .bind(strategy_type)
    .bind(instrument)
    .bind(granularity)
    .bind(parameters)
    .execute(pool)
    .await?;

    Ok(())
}

/// What the assignment's signals do (`{"type": "oanda"}` by default, or
/// `{"type": "share_alert", ...}`).
pub(crate) async fn set_action(pool: &PgPool, id: Uuid, action: &Value) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE live_strategies SET action = $2, updated_at = now() WHERE id = $1")
        .bind(id)
        .bind(action)
        .execute(pool)
        .await?;
    Ok(())
}

pub(crate) async fn get_live_strategy_by_id(
    pool: &PgPool,
    id: Uuid,
) -> Result<Option<LiveStrategyDetailRow>, sqlx::Error> {
    sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT ls.id, ls.strategy_type, ls.instrument, ls.granularity, {PARAMETERS_SQL} AS parameters, \
             ls.enabled, ls.curator_mode, ls.created_at, ls.updated_at \
         FROM live_strategies ls JOIN strategies s ON s.id = ls.strategy_id \
         WHERE ls.id = $1"
    )))
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
    let result = sqlx::query(sqlx::AssertSqlSafe(format!(
        "UPDATE live_strategies \
         SET strategy_type = $1, instrument = $2, instrument_id = {}, granularity = $3, \
             parameters = $4, updated_at = NOW() \
         WHERE id = $5",
        instruments_repo::id_for_name_sql("$2")
    )))
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
    executor: impl sqlx::PgExecutor<'_>,
    key: &str,
    value: &Value,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO trading_config (key, value, updated_at) VALUES ($1, $2, NOW()) ON CONFLICT (key) DO UPDATE SET value = $2, updated_at = NOW()",
    )
    .bind(key)
    .bind(value)
    .execute(executor)
    .await?;

    Ok(())
}

/// Every OANDA live strategy on a key, enabled or not. The evaluator needs
/// the disabled ones too: their open positions must still be managed to
/// exit. Share-alert assignments are decided by `engine::share_alerts`.
pub(crate) async fn list_for_instrument_granularity(
    pool: &PgPool,
    instrument: &str,
    granularity: &str,
) -> Result<Vec<LiveStrategy>, sqlx::Error> {
    sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT ls.id, ls.strategy_type, ls.instrument, ls.granularity, {PARAMETERS_SQL} AS parameters, ls.enabled \
         FROM live_strategies ls JOIN strategies s ON s.id = ls.strategy_id \
         WHERE ls.instrument = $1 AND ls.granularity = $2 AND ls.action->>'type' = 'oanda'"
    )))
    .bind(instrument)
    .bind(granularity)
    .fetch_all(pool)
    .await
}

/// An assignment whose action is a share alert, with what the alert check
/// needs: its strategy JSON and the market's Questrade ticker.
#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct ShareAlertAssignment {
    pub id: Uuid,
    pub instrument: String,
    pub parameters: Value,
    pub questrade_symbol: Option<String>,
}

/// The share-alert assignments among `ids` (others are left out).
pub(crate) async fn share_alert_assignments(
    pool: &PgPool,
    ids: &[Uuid],
) -> Result<Vec<ShareAlertAssignment>, sqlx::Error> {
    sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT ls.id, ls.instrument, {PARAMETERS_SQL} AS parameters, i.questrade_symbol \
         FROM live_strategies ls JOIN strategies s ON s.id = ls.strategy_id \
         LEFT JOIN instruments i ON i.id = ls.instrument_id \
         WHERE ls.id = ANY($1) AND ls.action->>'type' = 'share_alert'"
    )))
    .bind(ids)
    .fetch_all(pool)
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::AppState;
    use serde_json::json;

    fn rsi_dip_buy(instrument: &str, pct: f64) -> Value {
        json!({
            "version": "v1_composite",
            "strategy_id": null,
            "strategy_name": "split test dip-buy",
            "instrument": instrument,
            "granularity": "D",
            "components": {
                "r": {"type": "RsiReversion", "params": {"rsi_period": 2, "oversold": 20, "overbought": 80}}
            },
            "entry": {"long": "r.long"},
            "exit": {"long": "r.exit_long"},
            "stop": {"type": "AtrMultiple", "params": {"k": 3.0, "period": 14}},
            "sizing": {"type": "RiskPct", "params": {"pct": pct}},
            "max_hold_bars": 10
        })
    }

    async fn recipe_of(pool: &PgPool, id: Uuid) -> Uuid {
        sqlx::query_scalar("SELECT strategy_id FROM live_strategies WHERE id = $1")
            .bind(id)
            .fetch_one(pool)
            .await
            .unwrap()
    }

    async fn parameters_of(pool: &PgPool, instrument: &str) -> Value {
        list_for_instrument_granularity(pool, instrument, "D")
            .await
            .unwrap()
            .into_iter()
            .next()
            .expect("strategy listed")
            .parameters
    }

    #[tokio::test]
    #[ignore = "requires AURO_TEST_DATABASE_URL (migrated test database)"]
    async fn one_recipe_serves_many_assignments_and_reads_back_whole() {
        let pool = AppState::for_tests_with_test_db().await.db;
        let (spx, nas) = (Uuid::new_v4(), Uuid::new_v4());
        let (spx_params, nas_params) = (
            rsi_dip_buy("SPLIT_SPX", 0.01),
            rsi_dip_buy("SPLIT_NAS", 0.005),
        );

        insert_live_strategy(&pool, spx, "composite", "SPLIT_SPX", "D", &spx_params)
            .await
            .unwrap();
        insert_live_strategy(&pool, nas, "composite", "SPLIT_NAS", "D", &nas_params)
            .await
            .unwrap();

        // Same rules, different instrument and size: one recipe.
        let recipe = recipe_of(&pool, spx).await;
        assert_eq!(recipe_of(&pool, nas).await, recipe);
        assert_eq!(parameters_of(&pool, "SPLIT_SPX").await, spx_params);
        assert_eq!(parameters_of(&pool, "SPLIT_NAS").await, nas_params);

        // Changing one assignment's rules gives it its own recipe; the other keeps the old.
        let mut edited = nas_params.clone();
        edited["max_hold_bars"] = json!(5);
        update_live_strategy(&pool, nas, "composite", "SPLIT_NAS", "D", &edited)
            .await
            .unwrap();
        assert_ne!(recipe_of(&pool, nas).await, recipe);
        assert_eq!(recipe_of(&pool, spx).await, recipe);
        assert_eq!(parameters_of(&pool, "SPLIT_NAS").await, edited);

        sqlx::query("DELETE FROM live_strategies WHERE id = ANY($1)")
            .bind(vec![spx, nas])
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("DELETE FROM strategies WHERE name = 'split test dip-buy'")
            .execute(&pool)
            .await
            .unwrap();
    }

    #[tokio::test]
    #[ignore = "requires AURO_TEST_DATABASE_URL (migrated test database)"]
    async fn share_alerts_are_kept_from_the_oanda_evaluator() {
        let pool = AppState::for_tests_with_test_db().await.db;
        let (oanda, share) = (Uuid::new_v4(), Uuid::new_v4());
        let named = |pct| {
            let mut p = rsi_dip_buy("SPLIT_SHARE", pct);
            p["strategy_name"] = json!("share split test");
            p
        };
        insert_live_strategy(&pool, oanda, "composite", "SPLIT_SHARE", "D", &named(0.01))
            .await
            .unwrap();
        insert_live_strategy(&pool, share, "composite", "SPLIT_SHARE", "D", &named(0.02))
            .await
            .unwrap();
        set_action(&pool, share, &json!({"type": "share_alert", "amount": 500}))
            .await
            .unwrap();
        sqlx::query("UPDATE live_strategies SET enabled = true WHERE id = $1")
            .bind(share)
            .execute(&pool)
            .await
            .unwrap();

        let evaluated: Vec<Uuid> = list_for_instrument_granularity(&pool, "SPLIT_SHARE", "D")
            .await
            .unwrap()
            .into_iter()
            .map(|s| s.id)
            .collect();
        assert_eq!(evaluated, vec![oanda]);
        let alerts: Vec<Uuid> = share_alert_assignments(&pool, &[oanda, share])
            .await
            .unwrap()
            .into_iter()
            .map(|a| a.id)
            .collect();
        assert_eq!(alerts, vec![share]);
        let fed = crate::db::repositories::live_queries::enabled_strategy_keys(&pool)
            .await
            .unwrap();
        assert!(!fed.iter().any(|(i, _)| i == "SPLIT_SHARE"));

        sqlx::query("DELETE FROM live_strategies WHERE id = ANY($1)")
            .bind(vec![oanda, share])
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("DELETE FROM strategies WHERE name = 'share split test'")
            .execute(&pool)
            .await
            .unwrap();
    }
}
