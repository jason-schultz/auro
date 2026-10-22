//! Replay a live strategy's config through the backtest runner over the bars
//! stored in `candles`, and print the trades it takes in a window. Live and
//! backtest both consume the same OANDA bars, so a difference between this
//! output and `live_trades` is a live/backtest divergence worth chasing.
//!
//!   cargo run --example replay -- <live_strategy_id> <bars> <since YYYY-MM-DD>
//!
//! `bars` is how many most-recent bars to load (warm-up included); `since`
//! filters the printed trades. Reads DATABASE_URL from the environment/.env.

use std::str::FromStr;

use chrono::{NaiveDate, Utc};
use uuid::Uuid;

use auro::db::repositories::candles as candles_repo;
use auro::engine::strategy::{run_backtest, Strategy};
use auro::engine::types::Granularity;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    dotenvy::dotenv().ok();
    let args: Vec<String> = std::env::args().collect();
    let id = Uuid::from_str(
        args.get(1)
            .ok_or("usage: replay <live_strategy_id> <bars> <since>")?,
    )?;
    let bars: i64 = args.get(2).map(|s| s.parse()).transpose()?.unwrap_or(6000);
    let since = args
        .get(3)
        .map(|s| NaiveDate::from_str(s))
        .transpose()?
        .map(|d| d.and_hms_opt(0, 0, 0).unwrap().and_utc())
        .unwrap_or(Utc::now() - chrono::Duration::days(7));

    let pool = sqlx::PgPool::connect(&std::env::var("DATABASE_URL")?).await?;
    let parameters: serde_json::Value =
        sqlx::query_scalar("SELECT parameters FROM live_strategies WHERE id = $1")
            .bind(id)
            .fetch_one(&pool)
            .await?;
    let strategy: Strategy = serde_json::from_value(parameters)?;
    let granularity = Granularity::from_str(strategy.granularity.as_str())?;

    let candles =
        candles_repo::load_recent_candles(&pool, &strategy.instrument, granularity, bars).await?;
    println!(
        "{} {} — {} bars from {} to {}",
        strategy.instrument,
        granularity,
        candles.len(),
        candles
            .first()
            .map(|c| c.time.to_string())
            .unwrap_or_default(),
        candles
            .last()
            .map(|c| c.time.to_string())
            .unwrap_or_default()
    );

    let trades = run_backtest(&candles, &strategy);
    println!(
        "{} trades in window, {} since {}",
        trades.len(),
        trades.iter().filter(|t| t.entry_time >= since).count(),
        since.date_naive()
    );
    for t in trades.iter().filter(|t| t.entry_time >= since) {
        println!(
            "{:?} entry {} @ {:.1}  exit {} @ {:.1}  {:+.3}%  {:?}",
            t.direction,
            t.entry_time.format("%m-%d %H:%M"),
            t.entry_price,
            t.exit_time.format("%m-%d %H:%M"),
            t.exit_price,
            t.pnl_percent * 100.0,
            t.exit_reason
        );
    }
    Ok(())
}
