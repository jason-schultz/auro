use sqlx::PgPool;
use uuid::Uuid;

pub(crate) async fn is_trading_enabled(pool: &PgPool) -> Result<bool, sqlx::Error> {
    let result =
        sqlx::query_scalar!("SELECT value FROM trading_config WHERE key = 'trading_enabled'")
            .fetch_optional(pool)
            .await?;

    Ok(result
        .and_then(|value| value.as_str().map(|s| s == "true"))
        .unwrap_or(false))
}

pub(crate) async fn all_strategy_instruments(pool: &PgPool) -> Result<Vec<String>, sqlx::Error> {
    sqlx::query_scalar!("SELECT DISTINCT instrument FROM live_strategies")
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
    let strategy_count = sqlx::query_scalar!(
        "SELECT COUNT(*) FROM live_strategies \
         WHERE instrument = $1 \
         AND ($2::uuid IS NULL OR id != $2)",
        instrument,
        exclude_strategy_id,
    )
    .fetch_one(pool)
    .await?;

    Ok(strategy_count.unwrap_or(0))
}

pub(crate) async fn open_trade_count_for_instrument(
    pool: &PgPool,
    instrument: &str,
) -> Result<i64, sqlx::Error> {
    let open_count = sqlx::query_scalar!(
        "SELECT COUNT(*) FROM live_trades WHERE instrument = $1 AND status = 'open'",
        instrument
    )
    .fetch_one(pool)
    .await?;

    Ok(open_count.unwrap_or(0))
}

pub(crate) async fn open_trade_count_for_strategy(
    pool: &PgPool,
    strategy_id: Uuid,
) -> Result<i64, sqlx::Error> {
    let open_count = sqlx::query_scalar!(
        "SELECT COUNT(*) FROM live_trades WHERE live_strategy_id = $1 AND status = 'open'",
        strategy_id,
    )
    .fetch_one(pool)
    .await?;

    Ok(open_count.unwrap_or(0))
}

pub(crate) async fn instrument_unit_caps(pool: &PgPool) -> Result<Vec<(String, i64)>, sqlx::Error> {
    sqlx::query_as("SELECT instrument, max_units FROM instrument_unit_caps")
        .fetch_all(pool)
        .await
}
