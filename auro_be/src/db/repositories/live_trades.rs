use chrono::{DateTime, Utc};
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use super::instruments as instruments_repo;
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
    pub mae_pct: Option<f64>,
    pub mfe_pct: Option<f64>,
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

    // `select_cols` is a literal; `status` and `limit` are bound parameters.
    match status {
        Some(status) if status != "all" => {
            sqlx::query_as::<_, LiveTradeListRow>(sqlx::AssertSqlSafe(format!(
                "{} WHERE lt.status = $1 ORDER BY lt.entry_time DESC LIMIT $2",
                select_cols
            )))
            .bind(status)
            .bind(limit)
            .fetch_all(pool)
            .await
        }
        _ => {
            sqlx::query_as::<_, LiveTradeListRow>(sqlx::AssertSqlSafe(format!(
                "{} ORDER BY lt.entry_time DESC LIMIT $1",
                select_cols
            )))
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
               ls.strategy_type, ls.parameters, ls.granularity, ls.enabled
        FROM live_trades lt
        LEFT JOIN live_strategies ls ON ls.id = lt.live_strategy_id
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
        lt.oanda_trade_id, ls.strategy_type, ls.granularity, lt.mae_pct, lt.mfe_pct \
        FROM live_trades lt \
        JOIN live_strategies ls ON ls.id = lt.live_strategy_id \
        WHERE lt.oanda_trade_id = $1 AND lt.status = 'open'",
    )
    .bind(oanda_trade_id)
    .fetch_optional(pool)
    .await
}

pub(crate) struct NewLiveTrade<'a> {
    pub live_strategy_id: Uuid,
    pub oanda_trade_id: &'a str,
    pub instrument: &'a str,
    pub direction: Direction,
    pub units: &'a str,
    pub entry_price: f64,
    pub stop_loss_price: f64,
    pub entry_reason: &'a str,
    pub indicators_at_entry: &'a Value,
    pub regime_at_entry: &'a str,
    pub sizing_metadata: &'a Value,
    /// Mid close of the decision bar.
    pub signal_price: f64,
    /// The fill the backtest would have assumed for that bar, and its spread.
    pub expected_entry_price: Option<f64>,
    pub entry_spread: Option<f64>,
}

pub(crate) async fn insert_open_trade(
    pool: &PgPool,
    trade: &NewLiveTrade<'_>,
) -> Result<(), sqlx::Error> {
    // The row id and entry time are set here, not left to column defaults:
    // the Ecto migration that owns this table defines neither.
    sqlx::query(sqlx::AssertSqlSafe(format!(
        "INSERT INTO live_trades \
            (id, entry_time, live_strategy_id, oanda_trade_id, instrument, instrument_id, \
             direction, units, entry_price, stop_loss_price, entry_reason, \
             indicators_at_entry, regime_at_entry, sizing_metadata, \
             signal_price, expected_entry_price, entry_spread, status) \
         VALUES ($15, $16, $1, $2, $3, {}, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, 'open')",
        instruments_repo::id_for_name_sql("$3")
    )))
    .bind(trade.live_strategy_id)
    .bind(trade.oanda_trade_id)
    .bind(trade.instrument)
    .bind(trade.direction)
    .bind(trade.units)
    .bind(trade.entry_price)
    .bind(trade.stop_loss_price)
    .bind(trade.entry_reason)
    .bind(trade.indicators_at_entry)
    .bind(trade.regime_at_entry)
    .bind(trade.sizing_metadata)
    .bind(trade.signal_price)
    .bind(trade.expected_entry_price)
    .bind(trade.entry_spread)
    .bind(Uuid::new_v4())
    .bind(Utc::now())
    .execute(pool)
    .await?;
    Ok(())
}

pub(crate) struct ClosedLiveTrade<'a> {
    pub oanda_trade_id: &'a str,
    /// `None` when OANDA reported neither a fill price nor a closed trade
    /// price: the row records that the fill is unknown rather than a guess.
    pub exit_price: Option<f64>,
    pub pnl_percent: Option<f64>,
    pub realized_pl: Option<f64>,
    pub exit_reason: &'a str,
    pub stop_loss_state_at_close: &'a str,
    /// The backtest's assumed exit fill for the decision bar, and its spread.
    pub expected_exit_price: Option<f64>,
    pub exit_spread: Option<f64>,
}

pub(crate) async fn mark_closed(
    pool: &PgPool,
    trade: &ClosedLiveTrade<'_>,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        r#"
        UPDATE live_trades
        SET exit_price = $1, exit_time = NOW(), pnl_percent = $2,
            pnl = $3, exit_reason = $4, status = 'closed',
            stop_loss_state_at_close = $5, expected_exit_price = $6, exit_spread = $7,
            updated_at = NOW()
        WHERE oanda_trade_id = $8
        "#,
    )
    .bind(trade.exit_price)
    .bind(trade.pnl_percent)
    .bind(trade.realized_pl)
    .bind(trade.exit_reason)
    .bind(trade.stop_loss_state_at_close)
    .bind(trade.expected_exit_price)
    .bind(trade.exit_spread)
    .bind(trade.oanda_trade_id)
    .execute(pool)
    .await?;
    Ok(())
}

/// Ratchet an open trade's adverse/favourable excursions; never lowers them.
pub(crate) async fn record_excursions(
    pool: &PgPool,
    oanda_trade_id: &str,
    mae_pct: f64,
    mfe_pct: f64,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        r#"UPDATE live_trades
        SET mae_pct = GREATEST(COALESCE(mae_pct, 0), $1),
            mfe_pct = GREATEST(COALESCE(mfe_pct, 0), $2),
            updated_at = NOW()
        WHERE oanda_trade_id = $3 AND status = 'open'"#,
    )
    .bind(mae_pct)
    .bind(mfe_pct)
    .bind(oanda_trade_id)
    .execute(pool)
    .await?;
    Ok(())
}
