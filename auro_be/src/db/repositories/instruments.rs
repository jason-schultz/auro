//! `instruments`, the security master (Opus migration
//! `20261023160000_create_instruments`). Opus owns the rows (the
//! instruments page adds listings and flips feed flags); Rust reads them to
//! know what to fetch and records the vendor ids it learns along the way.

use sqlx::PgPool;

use crate::engine::instrument::{Instrument, InstrumentId};

/// SQL for the master's id of the vendor spelling held in bind parameter
/// `param`, for the dual-write period while the older tables still carry
/// the instrument as text. Each vendor column is unique, and one spelling
/// never names two listings, so the subquery yields at most one id.
pub fn id_for_name_sql(param: &str) -> String {
    format!(
        "(SELECT id FROM instruments \
          WHERE oanda_symbol = {p} OR questrade_symbol = {p} OR massive_ticker = {p})",
        p = param
    )
}

// The column list is the only assembled piece of these queries.
const COLUMNS: &str = "id, symbol, exchange, currency, asset_class, figi, active, \
     oanda_symbol, questrade_symbol, questrade_symbol_id, massive_ticker, \
     feed_questrade_bars, feed_massive_daily, feed_options_chain";

/// The listing Questrade calls `symbol` (`RY.TO`, `SPY`), if it is in the master.
pub async fn find_by_questrade_symbol(
    pool: &PgPool,
    symbol: &str,
) -> Result<Option<Instrument>, sqlx::Error> {
    sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {COLUMNS} FROM instruments WHERE questrade_symbol = $1"
    )))
    .bind(symbol)
    .fetch_optional(pool)
    .await
}

/// The listing Massive calls `ticker`, if it is in the master.
pub async fn find_by_massive_ticker(
    pool: &PgPool,
    ticker: &str,
) -> Result<Option<Instrument>, sqlx::Error> {
    sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {COLUMNS} FROM instruments WHERE massive_ticker = $1"
    )))
    .bind(ticker)
    .fetch_optional(pool)
    .await
}

/// Listings with a Questrade spelling whose Questrade id is still unknown,
/// or every such listing when `all` is set (to refresh exchange/currency).
pub async fn questrade_unresolved(
    pool: &PgPool,
    all: bool,
) -> Result<Vec<Instrument>, sqlx::Error> {
    sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {COLUMNS} FROM instruments \
         WHERE questrade_symbol IS NOT NULL AND ($1 OR questrade_symbol_id IS NULL) \
         ORDER BY exchange, symbol"
    )))
    .bind(all)
    .fetch_all(pool)
    .await
}

/// Record what Questrade reported for a listing: its numeric id and the
/// exchange and currency it is actually listed in.
pub async fn record_questrade_identity(
    pool: &PgPool,
    id: InstrumentId,
    symbol_id: i64,
    exchange: &str,
    currency: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "UPDATE instruments \
         SET questrade_symbol_id = $2, exchange = $3, currency = $4, updated_at = NOW() \
         WHERE id = $1",
    )
    .bind(id)
    .bind(symbol_id)
    .bind(exchange)
    .bind(currency)
    .execute(pool)
    .await?;
    Ok(())
}
