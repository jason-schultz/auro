use axum::extract::{Query, State};
use axum::Json;
use chrono::{Duration, Utc};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::brokers::oanda::backfill;
use crate::db::repositories::candles as candles_repo;
use crate::engine::types::Granularity;
use crate::error::{AppError, AppResult};
use crate::state::AppState;

#[derive(Deserialize)]
pub struct CandleParams {
    pub instrument: String,
    pub granularity: Option<String>,
    pub count: Option<i64>,
}

fn parse_granularity(raw: Option<&str>) -> AppResult<Granularity> {
    raw.unwrap_or("H1")
        .parse()
        .map_err(|e: String| AppError::BadRequest(e))
}

/// Recent complete candles from the DB — the same rows the backtest and the
/// signal preview read, so the chart, its markers and the gates agree.
pub async fn get_candles(
    State(state): State<AppState>,
    Query(params): Query<CandleParams>,
) -> AppResult<Json<Value>> {
    let granularity = parse_granularity(params.granularity.as_deref())?;
    let count = params.count.unwrap_or(300).clamp(1, 5000);

    let candles =
        candles_repo::load_recent_candles(&state.db, &params.instrument, granularity, count)
            .await?;

    let data: Vec<Value> = candles
        .iter()
        .map(|c| {
            json!({
                "time": c.time,
                "open": c.mid.open,
                "high": c.mid.high,
                "low": c.mid.low,
                "close": c.mid.close,
                "volume": c.volume,
                "complete": true,
            })
        })
        .collect();

    Ok(Json(json!({
        "instrument": params.instrument,
        "granularity": granularity.as_str(),
        "candles": data,
    })))
}

#[derive(Deserialize)]
pub struct BackfillParams {
    pub instrument: String,
    pub granularity: Option<String>,
    pub days: Option<i64>,
}

/// Extend stored history back `days` days. Uses the same OANDA fetch as the
/// live candle feed; overlapping rows are overwritten with identical data.
pub async fn backfill(
    State(state): State<AppState>,
    Query(params): Query<BackfillParams>,
) -> AppResult<Json<Value>> {
    let granularity = parse_granularity(params.granularity.as_deref())?;
    let days = params.days.unwrap_or(365);
    let after = Utc::now() - Duration::days(days);

    let stored = backfill::backfill(
        &state.oanda,
        &state.db,
        &params.instrument,
        granularity,
        after,
    )
    .await?;

    tracing::info!(
        "Backfilled {} {} {} candles over {} days",
        stored,
        params.instrument,
        granularity,
        days
    );

    Ok(Json(json!({
        "instrument": params.instrument,
        "granularity": granularity.as_str(),
        "days": days,
        "candles_stored": stored,
    })))
}
