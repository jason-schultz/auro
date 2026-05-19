use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;

use crate::engine::types::{CandleRow, SignalAction, SignalReport};

pub async fn create_pool(database_url: &str) -> Result<PgPool, sqlx::Error> {
    let pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(database_url)
        .await?;

    tracing::info!("Connected to PostgreSQL");

    sqlx::migrate!("./migrations").run(&pool).await?;

    tracing::info!("Migrations applied");

    Ok(pool)
}

pub async fn upsert_candle(pool: &PgPool, row: &CandleRow) -> Result<(), sqlx::Error> {
    sqlx::query(
        r#"
        INSERT INTO candles (instrument, granularity, timestamp, open, high, low, close, volume, complete)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        ON CONFLICT (instrument, granularity, timestamp)
        DO UPDATE SET
            open = EXCLUDED.open,
            high = EXCLUDED.high,
            low = EXCLUDED.low,
            close = EXCLUDED.close,
            volume = EXCLUDED.volume,
            complete = EXCLUDED.complete
        "#,
    )
    .bind(&row.instrument)
    .bind(row.granularity.as_str())
    .bind(row.candle.time)
    .bind(row.candle.open)
    .bind(row.candle.high)
    .bind(row.candle.low)
    .bind(row.candle.close)
    .bind(row.candle.volume)
    .bind(row.complete)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn upsert_candles(pool: &PgPool, rows: &[CandleRow]) -> Result<usize, sqlx::Error> {
    let mut count = 0;
    for row in rows {
        upsert_candle(pool, row).await?;
        count += 1;
    }
    Ok(count)
}

pub async fn get_latest_candle_time(
    pool: &PgPool,
    instrument: &str,
    granularity: &str,
) -> Result<Option<chrono::DateTime<chrono::Utc>>, sqlx::Error> {
    let row: Option<(chrono::DateTime<chrono::Utc>,)> = sqlx::query_as(
        "SELECT timestamp FROM candles WHERE instrument = $1 AND granularity = $2 ORDER BY timestamp DESC LIMIT 1",
    )
    .bind(instrument)
    .bind(granularity)
    .fetch_optional(pool)
    .await?;

    Ok(row.map(|r| r.0))
}

pub async fn record_signal_event(pool: &PgPool, report: &SignalReport) -> Result<(), sqlx::Error> {
    let action = signal_action_label(&report.action);
    let payload = serde_json::json!({
        "strategy_id": report.strategy_id,
        "strategy_type": report.strategy_type,
        "instrument": report.instrument,
        "granularity": report.granularity.as_str(),
        "action": action,
        "price": report.price,
        "reason": report.reason,
        "oanda_trade_id": report.oanda_trade_id,
        "timestamp": chrono::Utc::now(),
    });
    let payload_text = payload.to_string();

    sqlx::query(
        r#"
        INSERT INTO signal_events
            (strategy_id, strategy_type, instrument, granularity, action, price, reason, oanda_trade_id, payload)
        VALUES
            ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        "#,
    )
    .bind(report.strategy_id)
    .bind(&report.strategy_type)
    .bind(&report.instrument)
    .bind(report.granularity.as_str())
    .bind(action)
    .bind(report.price)
    .bind(&report.reason)
    .bind(&report.oanda_trade_id)
    .bind(payload)
    .execute(pool)
    .await?;

    sqlx::query("SELECT pg_notify('signal_event', $1)")
        .bind(payload_text)
        .execute(pool)
        .await?;

    Ok(())
}

fn signal_action_label(action: &SignalAction) -> &'static str {
    match action {
        SignalAction::OpenedLong => "opened_long",
        SignalAction::OpenedShort => "opened_short",
        SignalAction::ClosedLong => "closed_long",
        SignalAction::ClosedShort => "closed_short",
        SignalAction::EntryRejected => "entry_rejected",
        SignalAction::ExitConditionsNotMet => "exit_conditions_not_met",
    }
}
