use chrono::{DateTime, Duration, Utc};
use sqlx::PgPool;

use crate::brokers::oanda::client::OandaClient;
use crate::db::repositories::candles as candles_repo;
use crate::engine::types::{Candle, CandleRow, Granularity};
use crate::error::AppResult;

/// OANDA's per-request candle limit.
const PAGE_SIZE: i32 = 5000;

/// Every complete candle strictly after `after`, oldest first. Pages through
/// OANDA's per-request limit. This is the only way candles enter Auro: the
/// historical backfill and the live candle feed both use it, so live bars and
/// backtest bars are byte-identical OANDA candles.
pub async fn fetch_complete_since(
    oanda: &OandaClient,
    instrument: &str,
    granularity: Granularity,
    after: DateTime<Utc>,
) -> AppResult<Vec<Candle>> {
    let mut candles: Vec<Candle> = Vec::new();

    loop {
        let newest = candles.last().map_or(after, |c| c.time);
        let cursor = newest + Duration::seconds(1);
        if cursor > Utc::now() {
            break;
        }

        let from = cursor.format("%Y-%m-%dT%H:%M:%SZ").to_string();
        let response = oanda
            .get_candles(
                instrument,
                granularity.as_str(),
                Some(PAGE_SIZE),
                Some(&from),
                None,
            )
            .await?;

        let page_len = response.candles.len();
        let page = response.candles.iter().filter_map(|c| c.complete_candle());
        let added = append_newer(&mut candles, page, newest);

        if added == 0 || page_len < PAGE_SIZE as usize {
            break;
        }
    }

    Ok(candles)
}

/// Append candles strictly newer than `newest`. OANDA snaps `from` back to
/// the start of the bar containing it, so each page repeats the previous
/// page's last bar; this drops it. Returns how many were appended.
fn append_newer(
    candles: &mut Vec<Candle>,
    page: impl Iterator<Item = Candle>,
    newest: DateTime<Utc>,
) -> usize {
    let before = candles.len();
    candles.extend(page.filter(|c| c.time > newest));
    candles.len() - before
}

/// Fetch and persist every complete candle strictly after `after`.
pub async fn backfill(
    oanda: &OandaClient,
    pool: &PgPool,
    instrument: &str,
    granularity: Granularity,
    after: DateTime<Utc>,
) -> AppResult<usize> {
    let rows: Vec<CandleRow> = fetch_complete_since(oanda, instrument, granularity, after)
        .await?
        .into_iter()
        .map(|candle| CandleRow {
            instrument: instrument.to_string(),
            granularity,
            candle,
        })
        .collect();

    Ok(candles_repo::upsert_candles(pool, &rows).await?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::TimeZone;

    fn candle(minute: u32) -> Candle {
        Candle {
            time: Utc.with_ymd_and_hms(2026, 10, 13, 12, minute, 0).unwrap(),
            mid: OHLC {
                open: 1.0,
                high: 1.0,
                low: 1.0,
                close: 1.0,
            },
            volume: 1,
            bid: None,
            ask: None,
        }
    }

    #[test]
    fn append_newer_drops_the_repeated_page_boundary_bar() {
        let mut candles = vec![candle(0), candle(5)];
        let newest = candles.last().unwrap().time;

        // OANDA's next page starts with the bar we already have.
        let added = append_newer(
            &mut candles,
            [candle(5), candle(10), candle(15)].into_iter(),
            newest,
        );

        assert_eq!(added, 2);
        let minutes: Vec<_> = candles
            .iter()
            .map(|c| c.time.format("%M").to_string())
            .collect();
        assert_eq!(minutes, ["00", "05", "10", "15"]);
    }

    #[test]
    fn append_newer_reports_zero_when_page_has_nothing_new() {
        let mut candles = vec![candle(5)];
        let added = append_newer(&mut candles, [candle(5)].into_iter(), candle(5).time);
        assert_eq!(added, 0);
        assert_eq!(candles.len(), 1);
    }
}
