use anyhow::Context;
use auro::config::Config;
use auro::db::create_pool;
use auro::oanda::client::OandaClient;
use auro::oanda::models::CandlestickData;
use chrono::{DateTime, Duration, Utc};
use sqlx::PgPool;
use tokio::time::{sleep, Duration as TokioDuration};

#[derive(Debug, Clone)]
struct Target {
    instrument: String,
    granularity: String,
}

#[derive(Debug, Clone)]
struct Ohlc {
    open: f64,
    high: f64,
    low: f64,
    close: f64,
}

const OANDA_BATCH_LIMIT: usize = 4000;
const REQUEST_PAUSE_MS: u64 = 175;

async fn load_targets(pool: &PgPool) -> anyhow::Result<Vec<Target>> {
    let rows: Vec<(String, String)> = sqlx::query_as(
        r#"
        SELECT DISTINCT c.instrument, c.granularity
        FROM candles c
        INNER JOIN live_strategies ls ON ls.instrument = c.instrument
        WHERE c.bid_close IS NULL
        ORDER BY c.instrument, c.granularity
        "#,
    )
    .fetch_all(pool)
    .await
    .context("failed loading bid/ask backfill targets")?;

    Ok(rows
        .into_iter()
        .map(|(instrument, granularity)| Target {
            instrument,
            granularity,
        })
        .collect())
}

async fn load_missing_timestamps(
    pool: &PgPool,
    target: &Target,
) -> anyhow::Result<Vec<DateTime<Utc>>> {
    let rows: Vec<(DateTime<Utc>,)> = sqlx::query_as(
        r#"
        SELECT timestamp
        FROM candles
        WHERE instrument = $1
          AND granularity = $2
          AND bid_close IS NULL
        ORDER BY timestamp ASC
        "#,
    )
    .bind(&target.instrument)
    .bind(&target.granularity)
    .fetch_all(pool)
    .await
    .with_context(|| {
        format!(
            "failed loading missing timestamps for {} {}",
            target.instrument, target.granularity
        )
    })?;

    Ok(rows.into_iter().map(|(ts,)| ts).collect())
}

fn granularity_step(granularity: &str) -> anyhow::Result<Duration> {
    let step = match granularity {
        "M1" => Duration::minutes(1),
        "M5" => Duration::minutes(5),
        "M15" => Duration::minutes(15),
        "H1" => Duration::hours(1),
        "H4" => Duration::hours(4),
        "D" => Duration::days(1),
        other => anyhow::bail!("unsupported granularity '{}'", other),
    };

    Ok(step)
}

fn parse_ohlc(data: Option<&CandlestickData>) -> Option<Ohlc> {
    let data = data?;
    Some(Ohlc {
        open: data.o.parse().ok()?,
        high: data.h.parse().ok()?,
        low: data.l.parse().ok()?,
        close: data.c.parse().ok()?,
    })
}

async fn backfill_target(
    pool: &PgPool,
    oanda: &OandaClient,
    target: &Target,
) -> anyhow::Result<usize> {
    let timestamps = load_missing_timestamps(pool, target).await?;
    if timestamps.is_empty() {
        return Ok(0);
    }

    let _step = granularity_step(&target.granularity)?;
    let total_batches = timestamps.len().div_ceil(OANDA_BATCH_LIMIT);
    let mut updated_total = 0usize;

    for (batch_index, chunk) in timestamps.chunks(OANDA_BATCH_LIMIT).enumerate() {
        let from = chunk
            .first()
            .expect("chunk is never empty")
            .format("%Y-%m-%dT%H:%M:%SZ")
            .to_string();

        // Use count instead of (from, to) range. OANDA's range-based query
        // counts ITS view of candles in the range (which can exceed our local
        // chunk size due to weekend/holiday/session-boundary differences) and
        // rejects with "Maximum value for 'count' exceeded" past 5000.
        // count-based query bounds the response size deterministically.
        let response = oanda
            .get_candles(
                &target.instrument,
                &target.granularity,
                Some(OANDA_BATCH_LIMIT as i32),
                Some(&from),
                None,
            )
            .await
            .with_context(|| {
                format!(
                    "failed OANDA request for {} {} starting at {}",
                    target.instrument, target.granularity, from
                )
            })?;

        let mut tx = pool.begin().await.context("failed beginning transaction")?;
        let mut updated_batch = 0usize;

        for candle in response.candles {
            let Some(bid) = parse_ohlc(candle.bid.as_ref()) else {
                continue;
            };
            let Some(ask) = parse_ohlc(candle.ask.as_ref()) else {
                continue;
            };

            let ts = DateTime::parse_from_rfc3339(&candle.time)
                .with_context(|| format!("invalid RFC3339 timestamp '{}'", candle.time))?
                .with_timezone(&Utc);

            let result = sqlx::query(
                r#"
                UPDATE candles
                SET bid_open = $1,
                    bid_high = $2,
                    bid_low = $3,
                    bid_close = $4,
                    ask_open = $5,
                    ask_high = $6,
                    ask_low = $7,
                    ask_close = $8
                WHERE instrument = $9
                  AND granularity = $10
                  AND timestamp = $11
                "#,
            )
            .bind(bid.open)
            .bind(bid.high)
            .bind(bid.low)
            .bind(bid.close)
            .bind(ask.open)
            .bind(ask.high)
            .bind(ask.low)
            .bind(ask.close)
            .bind(&target.instrument)
            .bind(&target.granularity)
            .bind(ts)
            .execute(&mut *tx)
            .await
            .context("failed updating candle bid/ask columns")?;

            updated_batch += result.rows_affected() as usize;
        }

        tx.commit().await.context("failed committing transaction")?;

        updated_total += updated_batch;

        println!(
            "[backfill] {} {}: {} candles updated, batch {}/{}",
            target.instrument,
            target.granularity,
            updated_batch,
            batch_index + 1,
            total_batches
        );

        sleep(TokioDuration::from_millis(REQUEST_PAUSE_MS)).await;
    }

    Ok(updated_total)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    let config = Config::from_env().context("failed to load env config")?;
    let pool = create_pool(&config.database_url)
        .await
        .context("failed to connect db")?;

    let oanda = OandaClient::new(
        &config.oanda_base_url,
        &config.oanda_stream_url,
        &config.oanda_api_key,
        &config.oanda_account_id,
    );

    let targets = load_targets(&pool).await?;
    if targets.is_empty() {
        println!("No bid/ask backfill targets found (all caught up).");
        return Ok(());
    }

    println!(
        "Found {} target instrument/granularity pairs",
        targets.len()
    );

    let mut grand_total = 0usize;
    for target in &targets {
        let updated = backfill_target(&pool, &oanda, target).await?;
        grand_total += updated;
    }

    println!(
        "\nBid/ask backfill complete. Total candles updated: {}",
        grand_total
    );

    Ok(())
}
