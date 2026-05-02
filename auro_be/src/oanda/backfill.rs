use chrono::{Duration, Utc};
use sqlx::PgPool;

use crate::db;
use crate::engine::types::{Candle, CandleRow, Granularity};
use crate::oanda::client::OandaClient;

const BACKFILL_INSTRUMENTS: &[&str] = &[
    "EUR_USD", "USD_CAD", "GBP_USD", "USD_JPY", "AUD_USD", "XAU_USD",
];

pub async fn backfill_candles(oanda: &OandaClient, pool: &PgPool, days: i64) {
    tracing::info!("Starting candle backfill ({} days)...", days);

    for instrument in BACKFILL_INSTRUMENTS {
        match backfill_instrument(oanda, pool, instrument, days).await {
            Ok(count) => {
                tracing::info!("Backfilled {} candles for {}", count, instrument);
            }
            Err(e) => {
                tracing::error!("Failed to backfill {}: {}", instrument, e);
            }
        }
    }

    tracing::info!("Backfill complete");
}

async fn backfill_instrument(
    oanda: &OandaClient,
    pool: &PgPool,
    instrument: &str,
    days: i64,
) -> Result<usize, Box<dyn std::error::Error>> {
    // Check if we already have data — if so, start from where we left off
    let start_time = match db::get_latest_candle_time(pool, instrument, "M1").await? {
        Some(latest) => latest + Duration::minutes(1),
        None => Utc::now() - Duration::days(days),
    };

    let from = start_time.format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let mut total_count = 0;

    // OANDA returns max 5000 candles per request, so we may need multiple calls
    let mut current_from = from;

    loop {
        let response = oanda
            .get_candles(instrument, "M1", Some(5000), Some(&current_from), None)
            .await?;

        if response.candles.is_empty() {
            break;
        }

        let rows: Vec<CandleRow> = response
            .candles
            .iter()
            .filter_map(|c| {
                let mid = c.mid.as_ref()?;
                let time = chrono::DateTime::parse_from_rfc3339(&c.time)
                    .ok()?
                    .with_timezone(&Utc);

                Some(CandleRow {
                    instrument: instrument.to_string(),
                    granularity: Granularity::M1,
                    complete: c.complete,
                    candle: Candle {
                        time,
                        open: mid.o.parse().ok()?,
                        high: mid.h.parse().ok()?,
                        low: mid.l.parse().ok()?,
                        close: mid.c.parse().ok()?,
                        volume: c.volume,
                    },
                })
            })
            .collect();

        let count = db::upsert_candles(pool, &rows).await?;
        total_count += count;

        // If we got less than 5000, we've caught up
        if response.candles.len() < 5000 {
            break;
        }

        // Move the window forward
        if let Some(last) = rows.last() {
            current_from = (last.candle.time + Duration::minutes(1))
                .format("%Y-%m-%dT%H:%M:%SZ")
                .to_string();
        } else {
            break;
        }
    }

    Ok(total_count)
}
