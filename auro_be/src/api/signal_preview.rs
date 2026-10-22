//! Signal preview for the FE strategy editor: backtest a composite strategy
//! config over the most recent candle window and return its entries and exits.
//!
//! Runs `strategy::run_backtest` — the same runner the pipeline gates use — so
//! the markers include stop-loss and time-stop exits exactly as the backtest
//! takes them. A trade still open at the end of the window has no exit marker.

use axum::extract::State;
use axum::Json;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::db::repositories::candles as candles_repo;
use crate::engine::strategy::{run_backtest, Strategy};
use crate::engine::types::{Direction, ExitReason};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

#[derive(Deserialize)]
pub struct SignalPreviewRequest {
    /// Full composite strategy config (same JSON the editor saves).
    pub parameters: Value,
    /// How many recent bars to scan for signals (chart window size).
    pub count: Option<i64>,
}

pub async fn preview_signals(
    State(state): State<AppState>,
    Json(req): Json<SignalPreviewRequest>,
) -> AppResult<Json<Value>> {
    let strategy: Strategy = serde_json::from_value(req.parameters)
        .map_err(|e| AppError::BadRequest(format!("invalid composite config: {e}")))?;

    let count = req.count.unwrap_or(300).clamp(10, 1000);
    let warmup = strategy.warmup() as i64;

    let candles = candles_repo::load_recent_candles(
        &state.db,
        &strategy.instrument,
        strategy.granularity,
        (count + warmup).min(5000),
    )
    .await?;

    let mut signals: Vec<Value> = Vec::new();
    let mut open_position: Option<Direction> = None;

    for trade in run_backtest(&candles, &strategy) {
        signals.push(signal_json(trade.entry_time, "entry", trade.direction));
        if trade.exit_reason == ExitReason::EndOfData {
            open_position = Some(trade.direction);
        } else {
            signals.push(signal_json(trade.exit_time, "exit", trade.direction));
        }
    }

    Ok(Json(json!({
        "instrument": strategy.instrument,
        "granularity": strategy.granularity.as_str(),
        "warmup": warmup,
        "signals": signals,
        "open_position": open_position.map(direction_str),
    })))
}

fn signal_json(time: DateTime<Utc>, kind: &str, direction: Direction) -> Value {
    json!({
        "time": time,
        "kind": kind,
        "direction": direction_str(direction),
    })
}

fn direction_str(direction: Direction) -> &'static str {
    match direction {
        Direction::Long => "long",
        Direction::Short => "short",
    }
}
