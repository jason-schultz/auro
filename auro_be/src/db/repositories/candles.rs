use chrono::{DateTime, Utc};
use sqlx::PgPool;

use crate::engine::daily_bars;
use crate::engine::types::{Candle, CandleRow, Granularity, OHLC};

/// One `candles` row. The single DB → `Candle` mapping; every loader goes
/// through `into_candle`.
#[derive(sqlx::FromRow)]
struct CandleDbRow {
    timestamp: DateTime<Utc>,
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    volume: i32,
    bid_open: Option<f64>,
    bid_high: Option<f64>,
    bid_low: Option<f64>,
    bid_close: Option<f64>,
    ask_open: Option<f64>,
    ask_high: Option<f64>,
    ask_low: Option<f64>,
    ask_close: Option<f64>,
}

fn ohlc(
    open: Option<f64>,
    high: Option<f64>,
    low: Option<f64>,
    close: Option<f64>,
) -> Option<OHLC> {
    Some(OHLC {
        open: open?,
        high: high?,
        low: low?,
        close: close?,
    })
}

impl CandleDbRow {
    fn into_candle(self) -> Candle {
        Candle {
            time: self.timestamp,
            mid: OHLC {
                open: self.open,
                high: self.high,
                low: self.low,
                close: self.close,
            },
            volume: self.volume,
            bid: ohlc(self.bid_open, self.bid_high, self.bid_low, self.bid_close),
            ask: ohlc(self.ask_open, self.ask_high, self.ask_low, self.ask_close),
        }
    }
}

const CANDLE_COLUMNS: &str = "timestamp, open, high, low, close, volume, \
     bid_open, bid_high, bid_low, bid_close, ask_open, ask_high, ask_low, ask_close";

// The SELECT strings below are assembled from the constant `CANDLE_COLUMNS`
// list only; every runtime value is bound, so they are safe to assert.
/// Full complete-candle history for an instrument/granularity, oldest first,
/// with daily index stub bars folded into the next bar (`engine::daily_bars`).
pub async fn load_candles(
    pool: &PgPool,
    instrument: &str,
    granularity: Granularity,
) -> Result<Vec<Candle>, sqlx::Error> {
    let rows: Vec<CandleDbRow> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {CANDLE_COLUMNS} FROM candles \
         WHERE instrument = $1 AND granularity = $2 AND complete = true \
         ORDER BY timestamp ASC"
    )))
    .bind(instrument)
    .bind(granularity.as_str())
    .fetch_all(pool)
    .await?;

    let candles = rows.into_iter().map(CandleDbRow::into_candle).collect();
    Ok(daily_bars::fold_stubs(instrument, granularity, candles))
}

/// Close of the newest complete bar, or None when the instrument has none.
pub async fn latest_close(
    pool: &PgPool,
    instrument: &str,
    granularity: Granularity,
) -> Result<Option<f64>, sqlx::Error> {
    sqlx::query_scalar(
        "SELECT close FROM candles WHERE instrument = $1 AND granularity = $2 AND complete = true \
         ORDER BY timestamp DESC LIMIT 1",
    )
    .bind(instrument)
    .bind(granularity.as_str())
    .fetch_optional(pool)
    .await
}

/// The most recent `limit` complete candles, oldest first, with daily index
/// stub bars folded into the next bar (`engine::daily_bars`), so a little
/// fewer than `limit` for those.
pub async fn load_recent_candles(
    pool: &PgPool,
    instrument: &str,
    granularity: Granularity,
    limit: i64,
) -> Result<Vec<Candle>, sqlx::Error> {
    let rows: Vec<CandleDbRow> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {CANDLE_COLUMNS} FROM candles \
         WHERE instrument = $1 AND granularity = $2 AND complete = true \
         ORDER BY timestamp DESC LIMIT $3"
    )))
    .bind(instrument)
    .bind(granularity.as_str())
    .bind(limit)
    .fetch_all(pool)
    .await?;

    let candles = rows
        .into_iter()
        .rev()
        .map(CandleDbRow::into_candle)
        .collect();
    Ok(daily_bars::fold_stubs(instrument, granularity, candles))
}

/// Timestamp of the newest complete candle, if any.
pub async fn latest_candle_time(
    pool: &PgPool,
    instrument: &str,
    granularity: Granularity,
) -> Result<Option<DateTime<Utc>>, sqlx::Error> {
    sqlx::query_scalar(
        "SELECT MAX(timestamp) FROM candles \
         WHERE instrument = $1 AND granularity = $2 AND complete = true",
    )
    .bind(instrument)
    .bind(granularity.as_str())
    .fetch_one(pool)
    .await
}

/// Timestamp of the oldest complete candle, if any.
pub async fn earliest_candle_time(
    pool: &PgPool,
    instrument: &str,
    granularity: Granularity,
) -> Result<Option<DateTime<Utc>>, sqlx::Error> {
    sqlx::query_scalar(
        "SELECT MIN(timestamp) FROM candles \
         WHERE instrument = $1 AND granularity = $2 AND complete = true",
    )
    .bind(instrument)
    .bind(granularity.as_str())
    .fetch_one(pool)
    .await
}

/// `(timestamp, close)` of the complete candles in `[from, to]`, oldest first.
pub async fn closes_between(
    pool: &PgPool,
    instrument: &str,
    granularity: Granularity,
    from: DateTime<Utc>,
    to: DateTime<Utc>,
) -> Result<Vec<(DateTime<Utc>, f64)>, sqlx::Error> {
    sqlx::query_as(
        "SELECT timestamp, close FROM candles \
         WHERE instrument = $1 AND granularity = $2 AND complete = true \
           AND timestamp BETWEEN $3 AND $4 \
         ORDER BY timestamp ASC",
    )
    .bind(instrument)
    .bind(granularity.as_str())
    .bind(from)
    .bind(to)
    .fetch_all(pool)
    .await
}

/// Put every stored bar of `instrument` (all granularities) that starts
/// before `before` on a vendor's new scale: prices ÷ `ratio`, volume ×
/// `ratio` (a 2:1 split is 2.0). For history a vendor re-adjusted after a
/// split and won't refetch in full. Returns the bars changed.
pub async fn rescale_before(
    pool: &PgPool,
    instrument: &str,
    before: DateTime<Utc>,
    ratio: f64,
) -> Result<u64, sqlx::Error> {
    Ok(sqlx::query(
        "UPDATE candles SET            open = open / $3, high = high / $3, low = low / $3, close = close / $3,            bid_open = bid_open / $3, bid_high = bid_high / $3,            bid_low = bid_low / $3, bid_close = bid_close / $3,            ask_open = ask_open / $3, ask_high = ask_high / $3,            ask_low = ask_low / $3, ask_close = ask_close / $3,            volume = LEAST(ROUND(volume * $3), 2147483647)::int          WHERE instrument = $1 AND timestamp < $2",
    )
    .bind(instrument)
    .bind(before)
    .bind(ratio)
    .execute(pool)
    .await?
    .rows_affected())
}

/// Rows per INSERT statement. Keeps each statement's arrays modest while
/// cutting round-trips by three orders of magnitude for backfills.
const UPSERT_CHUNK: usize = 2000;

/// Insert or overwrite complete candles. Overwrite makes a re-fetch heal any
/// row an older code path stored as incomplete or tick-approximated.
pub async fn upsert_candles(pool: &PgPool, rows: &[CandleRow]) -> Result<usize, sqlx::Error> {
    for chunk in rows.chunks(UPSERT_CHUNK) {
        upsert_chunk(pool, chunk).await?;
    }
    Ok(rows.len())
}

async fn upsert_chunk(pool: &PgPool, rows: &[CandleRow]) -> Result<(), sqlx::Error> {
    let col = |f: fn(&CandleRow) -> f64| rows.iter().map(f).collect::<Vec<f64>>();
    let opt = |f: fn(&CandleRow) -> Option<f64>| rows.iter().map(f).collect::<Vec<Option<f64>>>();

    sqlx::query(
        r#"
        INSERT INTO candles (
            instrument_id, instrument, granularity, timestamp,
            open, high, low, close, volume, complete,
            bid_open, bid_high, bid_low, bid_close,
            ask_open, ask_high, ask_low, ask_close
        )
        SELECT i.id, t.instrument, t.granularity, t.timestamp,
               t.open, t.high, t.low, t.close, t.volume, true,
               t.bid_open, t.bid_high, t.bid_low, t.bid_close,
               t.ask_open, t.ask_high, t.ask_low, t.ask_close
        FROM UNNEST(
            $1::varchar[], $2::varchar[], $3::timestamptz[],
            $4::float8[], $5::float8[], $6::float8[], $7::float8[], $8::int4[],
            $9::float8[], $10::float8[], $11::float8[], $12::float8[],
            $13::float8[], $14::float8[], $15::float8[], $16::float8[]
        ) AS t(instrument, granularity, timestamp, open, high, low, close, volume,
               bid_open, bid_high, bid_low, bid_close,
               ask_open, ask_high, ask_low, ask_close)
        -- Dual-write period: the id comes from the master by vendor spelling;
        -- a name not in the master stores NULL and phase 3 refuses it.
        LEFT JOIN instruments i
          ON i.oanda_symbol = t.instrument
          OR i.questrade_symbol = t.instrument
          OR i.massive_ticker = t.instrument
        ON CONFLICT (instrument, granularity, timestamp)
        DO UPDATE SET
            instrument_id = COALESCE(EXCLUDED.instrument_id, candles.instrument_id),
            open = EXCLUDED.open,
            high = EXCLUDED.high,
            low = EXCLUDED.low,
            close = EXCLUDED.close,
            volume = EXCLUDED.volume,
            complete = true,
            bid_open = EXCLUDED.bid_open,
            bid_high = EXCLUDED.bid_high,
            bid_low = EXCLUDED.bid_low,
            bid_close = EXCLUDED.bid_close,
            ask_open = EXCLUDED.ask_open,
            ask_high = EXCLUDED.ask_high,
            ask_low = EXCLUDED.ask_low,
            ask_close = EXCLUDED.ask_close
        "#,
    )
    .bind(
        rows.iter()
            .map(|r| r.instrument.clone())
            .collect::<Vec<_>>(),
    )
    .bind(
        rows.iter()
            .map(|r| r.granularity.as_str())
            .collect::<Vec<_>>(),
    )
    .bind(rows.iter().map(|r| r.candle.time).collect::<Vec<_>>())
    .bind(col(|r| r.candle.mid.open))
    .bind(col(|r| r.candle.mid.high))
    .bind(col(|r| r.candle.mid.low))
    .bind(col(|r| r.candle.mid.close))
    .bind(rows.iter().map(|r| r.candle.volume).collect::<Vec<_>>())
    .bind(opt(|r| r.candle.bid.as_ref().map(|o| o.open)))
    .bind(opt(|r| r.candle.bid.as_ref().map(|o| o.high)))
    .bind(opt(|r| r.candle.bid.as_ref().map(|o| o.low)))
    .bind(opt(|r| r.candle.bid.as_ref().map(|o| o.close)))
    .bind(opt(|r| r.candle.ask.as_ref().map(|o| o.open)))
    .bind(opt(|r| r.candle.ask.as_ref().map(|o| o.high)))
    .bind(opt(|r| r.candle.ask.as_ref().map(|o| o.low)))
    .bind(opt(|r| r.candle.ask.as_ref().map(|o| o.close)))
    .execute(pool)
    .await?;

    Ok(())
}
