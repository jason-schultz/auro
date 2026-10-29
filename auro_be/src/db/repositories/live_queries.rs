use sqlx::PgPool;
use uuid::Uuid;

pub(crate) async fn is_trading_enabled(pool: &PgPool) -> Result<bool, sqlx::Error> {
    let result: Option<serde_json::Value> =
        sqlx::query_scalar("SELECT value FROM trading_config WHERE key = 'trading_enabled'")
            .fetch_optional(pool)
            .await?;

    Ok(result
        .and_then(|value| value.as_str().map(|s| s == "true"))
        .unwrap_or(false))
}

pub(crate) async fn all_strategy_instruments(pool: &PgPool) -> Result<Vec<String>, sqlx::Error> {
    sqlx::query_scalar("SELECT DISTINCT instrument FROM live_strategies")
        .fetch_all(pool)
        .await
}

/// Every (instrument, granularity) with at least one enabled live strategy:
/// the pairs whose bars must reach the evaluator with the least delay.
pub(crate) async fn enabled_strategy_keys(
    pool: &PgPool,
) -> Result<Vec<(String, String)>, sqlx::Error> {
    sqlx::query_as("SELECT DISTINCT instrument, granularity FROM live_strategies WHERE enabled")
        .fetch_all(pool)
        .await
}

pub(crate) async fn strategy_count_for_instrument_excluding(
    pool: &PgPool,
    instrument: &str,
    exclude_strategy_id: Option<Uuid>,
) -> Result<i64, sqlx::Error> {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM live_strategies \
         WHERE instrument = $1 \
         AND ($2::uuid IS NULL OR id != $2)",
    )
    .bind(instrument)
    .bind(exclude_strategy_id)
    .fetch_one(pool)
    .await
}

pub(crate) async fn open_trade_count_for_instrument(
    pool: &PgPool,
    instrument: &str,
) -> Result<i64, sqlx::Error> {
    sqlx::query_scalar("SELECT COUNT(*) FROM live_trades WHERE instrument = $1 AND status = 'open'")
        .bind(instrument)
        .fetch_one(pool)
        .await
}

pub(crate) async fn open_trade_count_for_strategy(
    pool: &PgPool,
    strategy_id: Uuid,
) -> Result<i64, sqlx::Error> {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM live_trades WHERE live_strategy_id = $1 AND status = 'open'",
    )
    .bind(strategy_id)
    .fetch_one(pool)
    .await
}

/// When OANDA last closed one of the strategy's trades by itself (a stop,
/// trailing stop or take-profit hit mid-bar, or a broker close: the labels
/// Opus's reconciler writes), if ever. Exits the strategy's own rules make
/// at a bar close are not counted.
pub(crate) async fn last_broker_exit_time_for_strategy(
    pool: &PgPool,
    strategy_id: Uuid,
) -> Result<Option<chrono::DateTime<chrono::Utc>>, sqlx::Error> {
    sqlx::query_scalar(
        "SELECT MAX(exit_time) FROM live_trades \
         WHERE live_strategy_id = $1 AND status = 'closed' \
         AND exit_reason IN ('StopLoss', 'TrailingStop', 'TakeProfit', 'ClosedByBroker')",
    )
    .bind(strategy_id)
    .fetch_one(pool)
    .await
}

pub(crate) async fn instrument_unit_caps(pool: &PgPool) -> Result<Vec<(String, i64)>, sqlx::Error> {
    sqlx::query_as("SELECT instrument, max_units FROM instrument_unit_caps")
        .fetch_all(pool)
        .await
}
