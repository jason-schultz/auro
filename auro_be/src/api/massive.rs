use axum::extract::State;
use axum::Json;
use chrono::{DateTime, Duration, Utc};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::brokers::massive::models::AggBar;
use crate::db::repositories::candles as candles_repo;
use crate::engine::types::{Candle, CandleRow, Granularity};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

/// The free plan serves roughly two years of history; anything longer is a
/// request mistake, not a backfill.
const MAX_PERSIST_DAYS: i64 = 800;

fn default_persist_days() -> i64 {
    5
}

#[derive(Debug, Deserialize)]
pub struct PersistCandles {
    pub symbol: String,
    /// Our granularity name ("D", "M5", ...).
    pub granularity: String,
    /// Calendar days back from today to (re)fetch. Overlaps are harmless —
    /// the upsert overwrites identical rows — so a scheduler can pull a few
    /// days each run and a one-off can pull the whole plan window.
    #[serde(default = "default_persist_days")]
    pub days: i64,
}

/// Fetch `days` of `symbol` bars from Massive and upsert the completed ones
/// into `candles`. Same contract as the Questrade persist endpoint; this is
/// the US-equity source, Questrade stays the Canadian one.
pub async fn persist_candles(
    State(state): State<AppState>,
    Json(body): Json<PersistCandles>,
) -> AppResult<Json<Value>> {
    let Some(massive) = state.massive.as_ref() else {
        return Err(AppError::Internal("Massive not configured".into()));
    };
    let granularity: Granularity = body.granularity.parse().map_err(AppError::BadRequest)?;
    if !(1..=MAX_PERSIST_DAYS).contains(&body.days) {
        return Err(AppError::BadRequest(format!(
            "days must be in 1..={MAX_PERSIST_DAYS}, got {}",
            body.days
        )));
    }

    let symbol = body.symbol.trim().to_uppercase();
    let now = Utc::now();
    let from = (now - Duration::days(body.days)).date_naive();
    let to = now.date_naive();

    let raw = massive
        .get_aggregates(&symbol, granularity, from, to)
        .await?;

    // Only bars that have fully closed: a run during the session must not
    // store a still-forming bar that the next run would see differently.
    let rows = completed_rows(&raw, &symbol, granularity, now)?;

    let stored = candles_repo::upsert_candles(&state.db, &rows)
        .await
        .map_err(AppError::Database)?;
    tracing::info!(
        "Persisted {} Massive {} {} candles ({} days)",
        stored,
        symbol,
        granularity,
        body.days
    );

    Ok(Json(json!({
        "symbol": symbol,
        "granularity": granularity.as_str(),
        "days": body.days,
        "candles_fetched": raw.len(),
        "candles_stored": stored,
        "first": rows.first().map(|r| r.candle.time),
        "last": rows.last().map(|r| r.candle.time),
    })))
}

fn completed_rows(
    bars: &[AggBar],
    symbol: &str,
    granularity: Granularity,
    now: chrono::DateTime<Utc>,
) -> AppResult<Vec<CandleRow>> {
    Ok(bars
        .iter()
        .map(Candle::try_from)
        .collect::<AppResult<Vec<_>>>()?
        .into_iter()
        .filter(|c| completes_at(c.time, granularity) <= now)
        .map(|candle| CandleRow {
            instrument: symbol.to_string(),
            granularity,
            candle,
        })
        .collect())
}

/// When a bar stops changing. Intraday bars are final one bar after they
/// open. Massive stamps daily bars at midnight New York and keeps updating
/// them through extended hours, which end 20:00 New York, 20 hours later, so
/// the nightly 01:30 UTC run sees the day that just closed.
fn completes_at(open: DateTime<Utc>, granularity: Granularity) -> DateTime<Utc> {
    match granularity {
        Granularity::D => open + Duration::hours(20),
        other => open + Duration::minutes(other.minutes()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn bar(t: i64) -> AggBar {
        AggBar {
            t,
            o: 1.0,
            h: 1.0,
            l: 1.0,
            c: 1.0,
            v: 1.0,
        }
    }

    #[test]
    fn still_forming_bars_are_dropped() {
        // 10:00 and 10:05 UTC bars; "now" is 10:07, so only the 10:00 bar is complete.
        let now = Utc.with_ymd_and_hms(2026, 10, 16, 10, 7, 0).unwrap();
        let bars = vec![
            bar(now.timestamp_millis() - 7 * 60_000),
            bar(now.timestamp_millis() - 2 * 60_000),
        ];
        let rows = completed_rows(&bars, "spy", Granularity::M5, now).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].instrument, "spy");
        assert_eq!(rows[0].granularity, Granularity::M5);
    }

    #[test]
    fn todays_daily_bar_is_final_once_extended_hours_end() {
        // 01:00 UTC Oct 16 is 21:00 New York Oct 15: after-hours are over.
        let now = Utc.with_ymd_and_hms(2026, 10, 16, 1, 0, 0).unwrap();
        let today = Utc.with_ymd_and_hms(2026, 10, 15, 4, 0, 0).unwrap();
        let bars = vec![
            bar((today - Duration::days(1)).timestamp_millis()),
            bar(today.timestamp_millis()),
        ];
        let rows = completed_rows(&bars, "SPY", Granularity::D, now).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[1].candle.time, today);
    }

    #[test]
    fn todays_daily_bar_waits_for_extended_hours() {
        // 23:30 UTC is 19:30 New York: after-hours still trading.
        let now = Utc.with_ymd_and_hms(2026, 10, 15, 23, 30, 0).unwrap();
        let today = Utc.with_ymd_and_hms(2026, 10, 15, 4, 0, 0).unwrap();
        let yesterday = today - Duration::days(1);
        let bars = vec![
            bar(yesterday.timestamp_millis()),
            bar(today.timestamp_millis()),
        ];
        let rows = completed_rows(&bars, "SPY", Granularity::D, now).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].candle.time, yesterday);
    }
}
