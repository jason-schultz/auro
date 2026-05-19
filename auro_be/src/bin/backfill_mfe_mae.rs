use anyhow::Context;
use auro::config::Config;
use auro::db::create_pool;
use chrono::{DateTime, Utc};
use sqlx::PgPool;

#[derive(Debug)]
struct ClosedTrade {
    oanda_trade_id: String,
    instrument: String,
    direction: String,
    entry_price: f64,
    entry_time: DateTime<Utc>,
    exit_time: DateTime<Utc>,
}

async fn load_trades_needing_backfill(pool: &PgPool) -> anyhow::Result<Vec<ClosedTrade>> {
    #[allow(clippy::type_complexity)]
    let rows: Vec<(
        Option<String>,
        String,
        String,
        Option<f64>,
        DateTime<Utc>,
        Option<DateTime<Utc>>,
    )> = sqlx::query_as(
        "SELECT oanda_trade_id, instrument, direction, entry_price, entry_time, exit_time \
         FROM live_trades \
         WHERE status = 'closed' AND mfe_pct IS NULL \
           AND oanda_trade_id IS NOT NULL AND entry_price IS NOT NULL AND exit_time IS NOT NULL \
         ORDER BY entry_time ASC",
    )
    .fetch_all(pool)
    .await
    .context("failed to load trades needing MFE/MAE backfill")?;

    Ok(rows
        .into_iter()
        .filter_map(|(id, inst, dir, entry, entry_t, exit_t)| {
            Some(ClosedTrade {
                oanda_trade_id: id?,
                instrument: inst,
                direction: dir,
                entry_price: entry?,
                entry_time: entry_t,
                exit_time: exit_t?,
            })
        })
        .collect())
}

async fn fetch_extents(
    pool: &PgPool,
    instrument: &str,
    from: DateTime<Utc>,
    to: DateTime<Utc>,
) -> anyhow::Result<Option<(f64, f64)>> {
    let row: Option<(Option<f64>, Option<f64>)> = sqlx::query_as(
        "SELECT MAX(high), MIN(low) FROM candles \
         WHERE instrument = $1 AND granularity = 'M1' \
           AND timestamp >= $2 AND timestamp <= $3",
    )
    .bind(instrument)
    .bind(from)
    .bind(to)
    .fetch_optional(pool)
    .await
    .with_context(|| format!("failed to fetch extents for {}", instrument))?;

    Ok(row.and_then(|(hi, lo)| match (hi, lo) {
        (Some(h), Some(l)) => Some((h, l)),
        _ => None,
    }))
}

fn compute_mfe_mae(
    direction: &str,
    entry: f64,
    peak_high: f64,
    trough_low: f64,
) -> Option<(f64, f64)> {
    match direction {
        "Long" => {
            let mfe = (peak_high - entry) / entry;
            let mae = (entry - trough_low) / entry;
            Some((mfe, mae))
        }
        "Short" => {
            let mfe = (entry - trough_low) / entry;
            let mae = (peak_high - entry) / entry;
            Some((mfe, mae))
        }
        _ => None,
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    let config = Config::from_env().context("failed to load env config")?;
    let pool = create_pool(&config.database_url)
        .await
        .context("failed to connect db")?;

    let trades = load_trades_needing_backfill(&pool).await?;

    if trades.is_empty() {
        println!("No closed trades need MFE/MAE backfill.");
        return Ok(());
    }

    println!(
        "Found {} closed trades needing MFE/MAE backfill",
        trades.len()
    );

    let mut updated = 0usize;
    let mut no_candles = 0usize;
    let mut bad_direction = 0usize;

    for trade in &trades {
        let extents =
            fetch_extents(&pool, &trade.instrument, trade.entry_time, trade.exit_time).await?;

        let Some((peak_high, trough_low)) = extents else {
            println!(
                "  [skip] {} {} ({}): no M1 candles between {} and {}",
                trade.oanda_trade_id,
                trade.instrument,
                trade.direction,
                trade.entry_time,
                trade.exit_time
            );
            no_candles += 1;
            continue;
        };

        let Some((mfe, mae)) =
            compute_mfe_mae(&trade.direction, trade.entry_price, peak_high, trough_low)
        else {
            println!(
                "  [skip] {} {}: unrecognized direction '{}'",
                trade.oanda_trade_id, trade.instrument, trade.direction
            );
            bad_direction += 1;
            continue;
        };

        sqlx::query(
            "UPDATE live_trades SET mfe_pct = $1, mae_pct = $2, updated_at = NOW() \
             WHERE oanda_trade_id = $3 AND status = 'closed' AND mfe_pct IS NULL",
        )
        .bind(mfe)
        .bind(mae)
        .bind(&trade.oanda_trade_id)
        .execute(&pool)
        .await
        .with_context(|| format!("failed to update {}", trade.oanda_trade_id))?;

        updated += 1;
    }

    println!("\nUpdated: {}", updated);
    println!("Skipped (no M1 candles in window): {}", no_candles);
    println!("Skipped (unrecognized direction): {}", bad_direction);

    let remaining: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM live_trades WHERE status = 'closed' AND mfe_pct IS NULL",
    )
    .fetch_one(&pool)
    .await
    .context("failed counting remaining NULL mfe_pct rows")?;

    println!("Remaining NULL mfe_pct rows: {}", remaining);

    Ok(())
}
