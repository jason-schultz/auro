use chrono::{DateTime, Utc};
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::engine::types::{Direction, Granularity};

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct LiveAggregateRow {
    pub strategy_id: Uuid,
    pub num_trades: i64,
    pub wins: i64,
    pub losses: i64,
    pub total_return: f64,
    pub avg_win: f64,
    pub avg_loss: f64,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct StrategyTradeRow {
    pub id: Uuid,
    pub oanda_trade_id: Option<String>,
    pub instrument: String,
    pub direction: String,
    pub units: String,
    pub entry_price: Option<f64>,
    pub exit_price: Option<f64>,
    pub entry_time: DateTime<Utc>,
    pub exit_time: Option<DateTime<Utc>>,
    pub stop_loss_price: Option<f64>,
    pub take_profit_price: Option<f64>,
    pub entry_reason: Option<String>,
    pub exit_reason: Option<String>,
    pub status: String,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct LiveTradeListRow {
    pub id: Uuid,
    pub live_strategy_id: Option<Uuid>,
    pub oanda_trade_id: Option<String>,
    pub instrument: String,
    pub direction: String,
    pub units: String,
    pub entry_price: Option<f64>,
    pub exit_price: Option<f64>,
    pub entry_time: DateTime<Utc>,
    pub exit_time: Option<DateTime<Utc>>,
    pub pnl_percent: Option<f64>,
    pub entry_reason: Option<String>,
    pub exit_reason: Option<String>,
    pub status: String,
    pub strategy_type: Option<String>,
    pub parameters: Option<Value>,
    pub granularity: Option<String>,
    pub indicators_at_entry: Option<Value>,
    pub regime_at_entry: Option<String>,
    pub mae_pct: Option<f64>,
    pub mfe_pct: Option<f64>,
    pub stop_loss_state_at_close: Option<String>,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct TradeDetailRow {
    pub id: Uuid,
    pub live_strategy_id: Option<Uuid>,
    pub oanda_trade_id: Option<String>,
    pub instrument: String,
    pub direction: String,
    pub units: String,
    pub entry_price: Option<f64>,
    pub exit_price: Option<f64>,
    pub entry_time: DateTime<Utc>,
    pub exit_time: Option<DateTime<Utc>>,
    pub pnl_percent: Option<f64>,
    pub entry_reason: Option<String>,
    pub exit_reason: Option<String>,
    pub status: String,
    pub indicators_at_entry: Option<Value>,
    pub regime_at_entry: Option<String>,
    pub stop_loss_state_at_close: Option<String>,
    pub strategy_type: Option<String>,
    pub parameters: Option<Value>,
    pub granularity: Option<String>,
    pub enabled: Option<bool>,
    pub max_position_size: Option<String>,
    pub backtest_run_id: Option<Uuid>,
    pub bt_strategy_name: Option<String>,
    pub bt_total_return: Option<f64>,
    pub bt_win_rate: Option<f64>,
    pub bt_sharpe_ratio: Option<f64>,
    pub bt_max_drawdown: Option<f64>,
    pub bt_num_trades: Option<i32>,
    pub bt_avg_win: Option<f64>,
    pub bt_avg_loss: Option<f64>,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct PrefillOpenPositionRow {
    pub live_strategy_id: Uuid,
    pub instrument: String,
    pub direction: Direction,
    pub entry_price: f64,
    pub entry_time: DateTime<Utc>,
    pub oanda_trade_id: String,
    pub strategy_type: String,
    pub granularity: Granularity,
}

pub(crate) async fn fetch_live_aggregates(
    pool: &PgPool,
    strategy_ids: &[Uuid],
) -> Result<Vec<LiveAggregateRow>, sqlx::Error> {
    if strategy_ids.is_empty() {
        return Ok(Vec::new());
    }

    sqlx::query_as(
        r#"
        SELECT
            live_strategy_id AS strategy_id,
            COUNT(*)::BIGINT AS num_trades,
            COUNT(*) FILTER (WHERE pnl_percent > 0)::BIGINT AS wins,
            COUNT(*) FILTER (WHERE pnl_percent <= 0)::BIGINT AS losses,
            COALESCE(SUM(pnl_percent), 0)::FLOAT8 AS total_return,
            COALESCE(AVG(pnl_percent) FILTER (WHERE pnl_percent > 0), 0)::FLOAT8 AS avg_win,
            COALESCE(AVG(pnl_percent) FILTER (WHERE pnl_percent <= 0), 0)::FLOAT8 AS avg_loss
        FROM live_trades
        WHERE status = 'closed' AND live_strategy_id = ANY($1)
        GROUP BY live_strategy_id
        "#,
    )
    .bind(strategy_ids)
    .fetch_all(pool)
    .await
}

pub(crate) async fn list_recent_for_strategy(
    pool: &PgPool,
    strategy_id: Uuid,
    limit: i64,
) -> Result<Vec<StrategyTradeRow>, sqlx::Error> {
    sqlx::query_as(
        r#"
        SELECT id, oanda_trade_id, instrument, direction, units,
               entry_price, exit_price, entry_time, exit_time,
               stop_loss_price, take_profit_price, entry_reason, exit_reason, status
        FROM live_trades
        WHERE live_strategy_id = $1
        ORDER BY entry_time DESC
        LIMIT $2
        "#,
    )
    .bind(strategy_id)
    .bind(limit)
    .fetch_all(pool)
    .await
}

pub(crate) async fn list_live_trades(
    pool: &PgPool,
    status: Option<&str>,
    limit: i64,
) -> Result<Vec<LiveTradeListRow>, sqlx::Error> {
    let select_cols = r#"
        SELECT lt.id, lt.live_strategy_id, lt.oanda_trade_id, lt.instrument, lt.direction, lt.units,
               lt.entry_price, lt.exit_price, lt.entry_time, lt.exit_time,
               lt.pnl_percent, lt.entry_reason, lt.exit_reason, lt.status,
               ls.strategy_type, ls.parameters, ls.granularity,
               lt.indicators_at_entry, lt.regime_at_entry,
               lt.mae_pct, lt.mfe_pct, lt.stop_loss_state_at_close
        FROM live_trades lt
        LEFT JOIN live_strategies ls ON ls.id = lt.live_strategy_id
    "#;

    match status {
        Some(status) if status != "all" => {
            sqlx::query_as::<_, LiveTradeListRow>(&format!(
                "{} WHERE lt.status = $1 ORDER BY lt.entry_time DESC LIMIT $2",
                select_cols
            ))
            .bind(status)
            .bind(limit)
            .fetch_all(pool)
            .await
        }
        _ => {
            sqlx::query_as::<_, LiveTradeListRow>(&format!(
                "{} ORDER BY lt.entry_time DESC LIMIT $1",
                select_cols
            ))
            .bind(limit)
            .fetch_all(pool)
            .await
        }
    }
}

pub(crate) async fn find_live_trade_detail(
    pool: &PgPool,
    id: Uuid,
) -> Result<Option<TradeDetailRow>, sqlx::Error> {
    sqlx::query_as(
        r#"
        SELECT lt.id, lt.live_strategy_id, lt.oanda_trade_id, lt.instrument, lt.direction, lt.units,
               lt.entry_price, lt.exit_price, lt.entry_time, lt.exit_time,
             lt.pnl_percent, lt.entry_reason, lt.exit_reason, lt.status,
             lt.indicators_at_entry, lt.regime_at_entry, lt.stop_loss_state_at_close,
               ls.strategy_type, ls.parameters, ls.granularity, ls.enabled,
               ls.max_position_size, ls.backtest_run_id,
               br.strategy_name AS bt_strategy_name,
               br.total_return AS bt_total_return,
               br.win_rate AS bt_win_rate,
               br.sharpe_ratio AS bt_sharpe_ratio,
               br.max_drawdown AS bt_max_drawdown,
               br.num_trades AS bt_num_trades,
               br.avg_win AS bt_avg_win,
               br.avg_loss AS bt_avg_loss
        FROM live_trades lt
        LEFT JOIN live_strategies ls ON ls.id = lt.live_strategy_id
        LEFT JOIN backtest_runs br ON br.id = ls.backtest_run_id
        WHERE lt.id = $1
        "#,
    )
    .bind(id)
    .fetch_optional(pool)
    .await
}

pub(crate) async fn find_open_trade_with_strategy_by_oanda_id(
    pool: &PgPool,
    oanda_trade_id: &str,
) -> Result<Option<PrefillOpenPositionRow>, sqlx::Error> {
    sqlx::query_as(
        "SELECT lt.live_strategy_id, lt.instrument, lt.direction, lt.entry_price, lt.entry_time, \
        lt.oanda_trade_id, ls.strategy_type, ls.granularity \
        FROM live_trades lt \
        JOIN live_strategies ls ON ls.id = lt.live_strategy_id \
        WHERE lt.oanda_trade_id = $1 AND lt.status = 'open'",
    )
    .bind(oanda_trade_id)
    .fetch_optional(pool)
    .await
}
