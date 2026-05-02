use axum::extract::{Path, State};
use axum::Json;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::engine::live::{evaluate_strategies, is_trading_enabled};
use crate::engine::types::{Granularity, SignalReport};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

#[derive(Deserialize)]
pub struct EvaluateRequest {
    pub target_slot: DateTime<Utc>,
    pub idempotency_key: String,
}

#[derive(Clone, Serialize)]
pub struct EvaluateResponse {
    pub evaluated: bool,
    pub target_slot: DateTime<Utc>,
    pub data_slot: Option<DateTime<Utc>>,
    pub staleness_candles: u32,
    pub duplicate: bool,
    pub signals: Vec<SignalReport>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

pub async fn evaluate(
    Path(granularity_str): Path<String>,
    State(state): State<AppState>,
    Json(body): Json<EvaluateRequest>,
) -> AppResult<Json<EvaluateResponse>> {
    // Parse granularity
    let granularity: Granularity = granularity_str
        .parse()
        .map_err(|e| AppError::BadRequest(format!("invalid granularity: {}", e)))?;

    {
        let mut cache = state.eval_cache.lock().unwrap();
        if let Some(cached) = cache.get(&body.idempotency_key) {
            tracing::info!("Cache hit for idempotency key {}", body.idempotency_key);
            let mut response = cached.clone();
            response.duplicate = true;
            return Ok(Json(response));
        }
    }

    // Check trading enabled
    let response = run_evaluation(&state, granularity, &body).await?;

    {
        let mut cache = state.eval_cache.lock().unwrap();
        cache.put(body.idempotency_key.clone(), response.clone());
    }

    Ok(Json(response))
}

async fn run_evaluation(
    state: &AppState,
    granularity: Granularity,
    body: &EvaluateRequest,
) -> Result<EvaluateResponse, AppError> {
    if !is_trading_enabled(&state.db).await {
        return Ok(EvaluateResponse {
            evaluated: false,
            target_slot: body.target_slot,
            data_slot: None,
            staleness_candles: 0,
            duplicate: false,
            signals: vec![],
            reason: Some("trading_disabled".to_string()),
        });
    }
    // Perform evaluation
    // Find instruments with enabled strategies at this granularity
    let instruments: Vec<(String,)> = sqlx::query_as(
        "SELECT DISTINCT instrument FROM live_strategies WHERE granularity = $1 AND enabled = true",
    )
    .bind(granularity.as_str())
    .fetch_all(&state.db)
    .await
    .map_err(AppError::from)?;

    if instruments.is_empty() {
        return Ok(EvaluateResponse {
            evaluated: true,
            target_slot: body.target_slot,
            data_slot: None,
            staleness_candles: 0,
            duplicate: false,
            signals: vec![],
            reason: Some("no_active_strategies".to_string()),
        });
    }

    // Evaluate each instrument
    let mut all_signals: Vec<SignalReport> = Vec::new();
    let mut oldest_data_slot: Option<DateTime<Utc>> = None;
    let mut any_evaluated = false;

    for (instrument,) in &instruments {
        let key = (instrument.clone(), granularity);

        // Snapshot the buffer
        let buffer_snapshot = {
            let buffers = state.live.buffers.read().await;
            buffers.get(&key).cloned()
        };

        let Some(buffer) = buffer_snapshot else {
            tracing::warn!(
                "[EVAL] No buffer for {} {}, skipping",
                instrument,
                granularity
            );
            continue;
        };

        // Track oldest data_slot across instruments
        if let Some(close_time) = buffer.candles.last().map(|c| c.time) {
            oldest_data_slot = Some(match oldest_data_slot {
                Some(existing) => existing.min(close_time),
                None => close_time,
            });
        }

        // Get the latest quote for this instrument (for bid/ask)
        let quote = {
            let quotes = state.live.last_quotes.read().await;
            quotes.get(instrument).cloned()
        };

        let Some(quote) = quote else {
            tracing::warn!("[EVAL] No quote for {}, skipping", instrument);
            continue;
        };

        any_evaluated = true;

        // Evaluate
        let mut open_positions = state.live.open_positions.write().await;
        match evaluate_strategies(
            &state.db,
            &state.oanda,
            instrument,
            &granularity,
            &buffer,
            quote.mid,
            quote.bid,
            quote.ask,
            &mut *open_positions,
        )
        .await
        {
            Ok(reports) => {
                tracing::info!("[EVAL] {} produced {} signals", instrument, reports.len());
                all_signals.extend(reports);
            }
            Err(e) => {
                tracing::error!("[EVAL] {} error: {}", instrument, e);
            }
        }
    }

    // Compute staleness
    let staleness_candles = match (oldest_data_slot, body.target_slot) {
        (Some(data), target) => {
            let diff = target - data;
            let unit_seconds = match granularity {
                Granularity::H1 => 3600,
                Granularity::M15 => 900,
                _ => 60,
            };
            (diff.num_seconds() / unit_seconds).max(0) as u32
        }
        _ => 0,
    };

    Ok(EvaluateResponse {
        evaluated: any_evaluated,
        target_slot: body.target_slot,
        data_slot: oldest_data_slot,
        staleness_candles,
        duplicate: false,
        signals: all_signals,
        reason: None,
    })
}
