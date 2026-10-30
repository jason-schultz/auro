//! `option_contracts`, `option_bars` and `option_quotes` (Opus-owned
//! migrations `20261022200000_create_option_tables`,
//! `20261022230000_create_option_quotes` and
//! `20261023160100_rekey_option_tables_on_instruments`). Contracts come
//! from whichever vendor listed the chain, bars are Massive history, quotes
//! are nightly Questrade snapshots; Rust reads all three for screens and
//! backtests.
//!
//! A contract is identified by (underlying listing, expiry, strike, kind)
//! and keyed by its surrogate `id`; the OCC ticker is a label, since the
//! same label names different contracts on dual-listed underlyings.

use chrono::{DateTime, NaiveDate, Utc};
use sqlx::PgPool;

use crate::brokers::massive::models::AggBar;
use crate::engine::instrument::InstrumentId;
use crate::engine::options::ContractSpec;
use crate::error::{AppError, AppResult};

/// Rows per INSERT statement (same reasoning as `candles::UPSERT_CHUNK`).
const UPSERT_CHUNK: usize = 2000;

/// A stored contract, as the screens and the bar fetcher see it.
#[derive(Debug, Clone, PartialEq, sqlx::FromRow)]
pub struct ContractRow {
    pub id: i64,
    pub ticker: String,
    pub underlying_instrument_id: InstrumentId,
    pub underlying: String,
    pub contract_type: String,
    pub expiration_date: NaiveDate,
    pub strike: f64,
    pub shares_per_contract: i32,
}

/// A contract's key after an upsert: the id bars and quotes point at,
/// with the label the vendor rows carry.
#[derive(Debug, Clone, PartialEq, sqlx::FromRow)]
pub struct StoredContract {
    pub id: i64,
    pub ticker: String,
}

/// One daily bar of one contract.
#[derive(Debug, Clone, PartialEq)]
pub struct OptionBarRow {
    pub contract_id: i64,
    pub ticker: String,
    pub time: DateTime<Utc>,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub volume: i32,
    pub transactions: Option<i32>,
}

impl OptionBarRow {
    pub fn from_agg(contract: &ContractRow, bar: &AggBar) -> AppResult<Self> {
        let time = DateTime::<Utc>::from_timestamp_millis(bar.t)
            .ok_or_else(|| AppError::Internal(format!("Bad Massive bar time {}", bar.t)))?;
        Ok(Self {
            contract_id: contract.id,
            ticker: contract.ticker.clone(),
            time,
            open: bar.o,
            high: bar.h,
            low: bar.l,
            close: bar.c,
            volume: bar.v.round().clamp(0.0, f64::from(i32::MAX)) as i32,
            transactions: bar.n.map(|n| n.clamp(0, i64::from(i32::MAX)) as i32),
        })
    }
}

/// One contract's quote at one capture, as the vendor reported it. Greeks
/// and `volatility` are stored as given (Questrade quotes `volatility` in
/// percent); `spot` is the underlying's price at the same capture so the
/// implied vol can be re-solved from the premium later.
#[derive(Debug, Clone, PartialEq)]
pub struct OptionQuoteRow {
    pub contract_id: i64,
    pub ticker: String,
    pub captured_at: DateTime<Utc>,
    /// Which vendor's quote this is (`questrade`).
    pub source: String,
    pub spot: f64,
    pub bid: Option<f64>,
    pub ask: Option<f64>,
    pub last: Option<f64>,
    pub bid_size: Option<i32>,
    pub ask_size: Option<i32>,
    pub volume: Option<i32>,
    pub open_interest: Option<i32>,
    pub volatility: Option<f64>,
    pub delta: Option<f64>,
    pub gamma: Option<f64>,
    pub theta: Option<f64>,
    pub vega: Option<f64>,
    pub rho: Option<f64>,
    /// How stale the vendor said the quote was; 0 = real-time.
    pub delay_seconds: Option<i32>,
}

/// Insert new contracts on `underlying`, refresh `last_seen_at` on known
/// ones, and return every contract's id with its ticker, in the order sent.
/// A known contract takes the ticker as sent, so the returned ticker is
/// always the caller's spelling (callers join on it).
pub async fn upsert_contracts(
    pool: &PgPool,
    underlying: InstrumentId,
    contracts: &[ContractSpec],
    seen_at: DateTime<Utc>,
) -> Result<Vec<StoredContract>, sqlx::Error> {
    let mut stored = Vec::with_capacity(contracts.len());
    for chunk in contracts.chunks(UPSERT_CHUNK) {
        let rows: Vec<StoredContract> = sqlx::query_as(
            r#"
            INSERT INTO option_contracts (
                ticker, underlying_instrument_id, underlying, contract_type,
                expiration_date, strike, shares_per_contract, exercise_style,
                primary_exchange, first_seen_at, last_seen_at
            )
            SELECT ticker, $10, underlying, contract_type, expiration_date, strike,
                   shares_per_contract, exercise_style, primary_exchange, $9, $9
            FROM UNNEST(
                $1::varchar[], $2::varchar[], $3::varchar[], $4::date[], $5::float8[],
                $6::int4[], $7::varchar[], $8::varchar[]
            ) AS t(ticker, underlying, contract_type, expiration_date, strike,
                   shares_per_contract, exercise_style, primary_exchange)
            ON CONFLICT (underlying_instrument_id, expiration_date, strike, contract_type)
            DO UPDATE SET
                ticker = EXCLUDED.ticker,
                last_seen_at = EXCLUDED.last_seen_at,
                exercise_style = COALESCE(EXCLUDED.exercise_style, option_contracts.exercise_style),
                primary_exchange = COALESCE(EXCLUDED.primary_exchange, option_contracts.primary_exchange)
            RETURNING id, ticker
            "#,
        )
        .bind(chunk.iter().map(|c| c.ticker.clone()).collect::<Vec<_>>())
        .bind(chunk.iter().map(|c| c.underlying.clone()).collect::<Vec<_>>())
        .bind(chunk.iter().map(|c| c.kind.as_str()).collect::<Vec<_>>())
        .bind(chunk.iter().map(|c| c.expiration).collect::<Vec<_>>())
        .bind(chunk.iter().map(|c| c.strike).collect::<Vec<_>>())
        .bind(chunk.iter().map(|c| c.shares_per_contract).collect::<Vec<_>>())
        .bind(chunk.iter().map(|c| c.exercise_style.clone()).collect::<Vec<_>>())
        .bind(chunk.iter().map(|c| c.primary_exchange.clone()).collect::<Vec<_>>())
        .bind(seen_at)
        .bind(underlying)
        .fetch_all(pool)
        .await?;
        stored.extend(rows);
    }
    Ok(stored)
}

/// Insert or overwrite daily bars.
pub async fn upsert_bars(pool: &PgPool, rows: &[OptionBarRow]) -> Result<usize, sqlx::Error> {
    for chunk in rows.chunks(UPSERT_CHUNK) {
        sqlx::query(
            r#"
            INSERT INTO option_bars (
                contract_id, ticker, timestamp, open, high, low, close, volume, transactions
            )
            SELECT * FROM UNNEST(
                $9::int8[], $1::varchar[], $2::timestamptz[], $3::float8[], $4::float8[],
                $5::float8[], $6::float8[], $7::int4[], $8::int4[]
            )
            ON CONFLICT (contract_id, timestamp) DO UPDATE SET
                open = EXCLUDED.open, high = EXCLUDED.high, low = EXCLUDED.low,
                close = EXCLUDED.close, volume = EXCLUDED.volume,
                transactions = EXCLUDED.transactions
            "#,
        )
        .bind(chunk.iter().map(|r| r.ticker.clone()).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.time).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.open).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.high).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.low).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.close).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.volume).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.transactions).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.contract_id).collect::<Vec<_>>())
        .execute(pool)
        .await?;
    }
    Ok(rows.len())
}

/// Store one capture's quotes. A repeated capture at the same instant is
/// ignored rather than overwritten; snapshots are append-only.
pub async fn insert_quotes(pool: &PgPool, rows: &[OptionQuoteRow]) -> Result<usize, sqlx::Error> {
    for chunk in rows.chunks(UPSERT_CHUNK) {
        sqlx::query(
            r#"
            INSERT INTO option_quotes (
                contract_id, ticker, captured_at, source, spot, bid, ask, last, bid_size,
                ask_size, volume, open_interest, volatility, delta, gamma, theta, vega,
                rho, delay_seconds
            )
            SELECT * FROM UNNEST(
                $19::int8[], $1::varchar[], $2::timestamptz[], $3::varchar[], $4::float8[],
                $5::float8[], $6::float8[], $7::float8[], $8::int4[], $9::int4[], $10::int4[],
                $11::int4[], $12::float8[], $13::float8[], $14::float8[], $15::float8[],
                $16::float8[], $17::float8[], $18::int4[]
            )
            ON CONFLICT (contract_id, captured_at) DO NOTHING
            "#,
        )
        .bind(chunk.iter().map(|r| r.ticker.clone()).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.captured_at).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.source.clone()).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.spot).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.bid).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.ask).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.last).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.bid_size).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.ask_size).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.volume).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.open_interest).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.volatility).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.delta).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.gamma).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.theta).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.vega).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.rho).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.delay_seconds).collect::<Vec<_>>())
        .bind(chunk.iter().map(|r| r.contract_id).collect::<Vec<_>>())
        .execute(pool)
        .await?;
    }
    Ok(rows.len())
}

/// The underlying price the newest stored option quote on `underlying` was
/// captured against (chain snapshot or held-leg quote), if any.
pub async fn latest_quote_spot(
    pool: &PgPool,
    underlying: &str,
) -> Result<Option<f64>, sqlx::Error> {
    sqlx::query_scalar(
        "SELECT q.spot FROM option_quotes q \
         JOIN option_contracts c ON c.id = q.contract_id \
         WHERE c.underlying = $1 \
         ORDER BY q.captured_at DESC LIMIT 1",
    )
    .bind(underlying)
    .fetch_optional(pool)
    .await
}

/// Contracts on `underlying` expiring in `[from, to]` with strikes in
/// `[lo, hi]`, nearest expiry first.
pub async fn list_contracts(
    pool: &PgPool,
    underlying: InstrumentId,
    expires_from: NaiveDate,
    expires_to: NaiveDate,
    strikes: Option<(f64, f64)>,
) -> Result<Vec<ContractRow>, sqlx::Error> {
    let (lo, hi) = strikes.unwrap_or((0.0, f64::MAX));
    sqlx::query_as(
        r#"
        SELECT id, ticker, underlying_instrument_id, underlying, contract_type,
               expiration_date, strike, shares_per_contract
        FROM option_contracts
        WHERE underlying_instrument_id = $1
          AND expiration_date BETWEEN $2 AND $3
          AND strike BETWEEN $4 AND $5
          AND contract_type IN ('call', 'put')
        ORDER BY expiration_date, strike, contract_type
        "#,
    )
    .bind(underlying)
    .bind(expires_from)
    .bind(expires_to)
    .bind(lo)
    .bind(hi)
    .fetch_all(pool)
    .await
}

/// The contracts with these ids on `underlying`; ids on another underlying
/// or not stored are left out.
pub async fn contracts_by_ids(
    pool: &PgPool,
    underlying: InstrumentId,
    ids: &[i64],
) -> Result<Vec<ContractRow>, sqlx::Error> {
    sqlx::query_as(
        r#"
        SELECT id, ticker, underlying_instrument_id, underlying, contract_type,
               expiration_date, strike, shares_per_contract
        FROM option_contracts
        WHERE underlying_instrument_id = $1 AND id = ANY($2)
        ORDER BY expiration_date, strike, contract_type
        "#,
    )
    .bind(underlying)
    .bind(ids)
    .fetch_all(pool)
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bar_row_from_agg_clamps_counts() {
        let bar = AggBar {
            t: 1_791_864_000_000,
            o: 1.0,
            h: 2.0,
            l: 0.5,
            c: 1.5,
            v: 1234.6,
            n: Some(77),
        };
        let contract = ContractRow {
            id: 1,
            ticker: "O:SPY261219C00650000".into(),
            underlying_instrument_id: InstrumentId(1),
            underlying: "SPY".into(),
            contract_type: "call".into(),
            expiration_date: NaiveDate::from_ymd_opt(2026, 12, 19).unwrap(),
            strike: 650.0,
            shares_per_contract: 100,
        };
        let row = OptionBarRow::from_agg(&contract, &bar).unwrap();
        assert_eq!(
            (row.contract_id, row.ticker.as_str()),
            (1, "O:SPY261219C00650000")
        );
        assert_eq!(row.time.to_rfc3339(), "2026-10-13T04:00:00+00:00");
        assert_eq!((row.volume, row.transactions), (1235, Some(77)));
        assert_eq!(row.close, 1.5);
    }
}
