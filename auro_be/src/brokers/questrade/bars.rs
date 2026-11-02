//! Storing Questrade bars: the one path for the nightly fetch
//! (`POST /api/questrade/candles/persist`) and the live bar feed
//! (`engine::live::stock_feed`), so both store a bar the same way.

use chrono::{DateTime, Utc};
use sqlx::PgPool;

use super::models::EquityCandle;
use crate::brokers::adjusted::{self, Rescaled};
use crate::brokers::{stock_bar_final_at, stock_day_open};
use crate::db::repositories::candles as candles_repo;
use crate::engine::types::{Candle, CandleRow, Granularity};
use crate::error::{AppError, AppResult};

/// What a store wrote.
pub struct Stored {
    /// The bars kept, in time order: closed ones only, one per time.
    pub rows: Vec<CandleRow>,
    /// Rows the write inserted or changed.
    pub written: usize,
    /// Older history put on a new split scale, if a split showed up.
    pub rescaled: Option<Rescaled>,
}

/// Store `raw` as `symbol`'s `granularity` bars, as of `now`:
/// - only bars that have closed (a still-forming bar would be stored
///   differently by the next fetch);
/// - daily bars stamped at midnight New York (`stock_day_open`);
/// - one bar per time: Questrade now and then sends a day twice (a midnight
///   bar and a 01:00 copy), and one write can't take both, so the first wins;
/// - daily bars come split-adjusted as of the fetch, so after a split the
///   stored history is put on the new scale.
pub async fn store(
    db: &PgPool,
    symbol: &str,
    granularity: Granularity,
    raw: &[EquityCandle],
    now: DateTime<Utc>,
) -> AppResult<Stored> {
    let rows: Vec<CandleRow> = raw
        .iter()
        .map(Candle::try_from)
        .collect::<AppResult<Vec<_>>>()?
        .into_iter()
        .map(|candle| match granularity {
            Granularity::D => Candle {
                time: stock_day_open(candle.time),
                ..candle
            },
            _ => candle,
        })
        .filter(|c| stock_bar_final_at(c.time, granularity) <= now)
        .map(|candle| CandleRow {
            instrument: symbol.to_string(),
            granularity,
            candle,
        })
        .collect();
    let rows = one_per_time(rows);

    let rescaled = adjusted::match_stored_scale(db, &rows)
        .await
        .map_err(AppError::Database)?;
    let written = candles_repo::upsert_candles(db, &rows)
        .await
        .map_err(AppError::Database)?;
    Ok(Stored {
        rows,
        written,
        rescaled,
    })
}

/// `rows` in time order with one row per time, the first of each kept.
pub(crate) fn one_per_time(mut rows: Vec<CandleRow>) -> Vec<CandleRow> {
    rows.sort_by_key(|r| r.candle.time);
    rows.dedup_by_key(|r| r.candle.time);
    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;

    #[test]
    fn a_day_sent_twice_is_stored_once() {
        let at = |s: &str| DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc);
        let row = |time: DateTime<Utc>, close: f64| CandleRow {
            instrument: "DIA".into(),
            granularity: Granularity::D,
            candle: Candle::from_trade_bar(
                time,
                OHLC {
                    open: close,
                    high: close,
                    low: close,
                    close,
                },
                0.0,
            ),
        };
        let day = stock_day_open(at("1999-10-05T00:00:00-04:00"));
        let copy = stock_day_open(at("1999-10-05T01:00:00-04:00"));
        let next = stock_day_open(at("1999-10-06T00:00:00-04:00"));
        let rows = one_per_time(vec![row(day, 104.0), row(copy, 104.0), row(next, 105.0)]);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[1].candle.time, next);
    }
}
