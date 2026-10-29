//! How a strategy did over its whole test history, for the strategy pages.
//!
//! Both run over the same bars as the pipeline's backtest (everything before
//! the sealed holdout) through the same runner, with financing, so the
//! numbers line up with the backtest result shown beside them.
//!
//! - `POST /api/strategy/report`: the strategy's running return against just
//!   holding the instrument, and its drawdown (`engine::report::equity`).
//! - `POST /api/strategy/trades`: every trade the backtest made.
//! - `POST /api/strategy/sensitivity`: the strategy re-run at a grid of
//!   nearby settings (up to 49), each judged by the backtest thresholds the
//!   pipeline uses, so a sturdy result shows as a neighbourhood that passes
//!   and a lucky one as a lone cell.
//!
//! The backtests are CPU work, so they run off the async runtime (a blocking
//! thread, and for a grid at most `WORKERS` threads) and never hold up the
//! live price stream. A daily strategy's grid takes under a second; a
//! 5-minute one over years of bars about 40.

use axum::extract::State;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::engine::pipeline::{
    self, backtest_stats_to_json, evaluate_thresholds, instrument_to_class, run_strategy, t_stat,
    StrategyConfig,
};
use crate::engine::report;
use crate::engine::stats::calculate_backtest_stats;
use crate::error::{AppError, AppResult};
use crate::state::AppState;

const MAX_CELLS: usize = 49;

/// Threads a sensitivity grid uses: half the cores on the 8-core machine it
/// runs on, so the live price stream is never starved.
pub(super) const WORKERS: usize = 4;

#[derive(Deserialize)]
pub struct ReportRequest {
    /// Full strategy JSON (as the signal preview takes it).
    pub parameters: Value,
}

#[derive(Deserialize)]
pub struct Axis {
    pub component: String,
    pub param: String,
    pub values: Vec<f64>,
}

#[derive(Deserialize)]
pub struct SensitivityRequest {
    pub parameters: Value,
    pub x: Axis,
    /// A second setting for a grid; without it, a single row.
    pub y: Option<Axis>,
}

pub async fn equity_report(
    State(state): State<AppState>,
    Json(req): Json<ReportRequest>,
) -> AppResult<Json<Value>> {
    let config = config_of(req.parameters)?;
    let candles = pipeline::load_exploration_candles(&state.db, &config).await?;
    let financing = pipeline::load_financing(&state.db).await?;

    let report = blocking(move || {
        let trades = run_strategy(&candles, &config, &financing)?;
        Ok(report::equity(&candles, &trades))
    })
    .await?;

    Ok(Json(json!({ "report": report })))
}

/// `POST /api/strategy/trades`: every trade the backtest made, oldest
/// first, for comparing a strategy's live trades with what its backtest
/// calls normal (Opus's drift check).
pub async fn backtest_trades(
    State(state): State<AppState>,
    Json(req): Json<ReportRequest>,
) -> AppResult<Json<Value>> {
    let config = config_of(req.parameters)?;
    let candles = pipeline::load_exploration_candles(&state.db, &config).await?;
    let financing = pipeline::load_financing(&state.db).await?;

    let body = blocking(move || {
        let trades = run_strategy(&candles, &config, &financing)?;
        let (from, to) = pipeline::span(&candles);
        Ok(json!({
            "from": from,
            "to": to,
            "trades": trades.iter().map(|t| json!({
                "entry_time": t.entry_time,
                "exit_time": t.exit_time,
                "pnl_percent": t.pnl_percent,
            })).collect::<Vec<_>>(),
        }))
    })
    .await?;

    Ok(Json(body))
}

pub async fn sensitivity(
    State(state): State<AppState>,
    Json(req): Json<SensitivityRequest>,
) -> AppResult<Json<Value>> {
    let rows = req.y.as_ref().map_or(1, |y| y.values.len());
    if req.x.values.is_empty() || req.x.values.len() * rows > MAX_CELLS {
        return Err(AppError::BadRequest(format!(
            "between 1 and {MAX_CELLS} settings to try"
        )));
    }

    let config = config_of(req.parameters)?;
    let candles = pipeline::load_exploration_candles(&state.db, &config).await?;
    let financing = pipeline::load_financing(&state.db).await?;
    let timeframe_class = config.granularity.timeframe_class();
    let thresholds = pipeline::load_thresholds(
        &state.db,
        "backtest",
        timeframe_class,
        instrument_to_class(&config.instrument),
        &config.strategy_type,
    )
    .await?;

    let cells = blocking(move || {
        let y_values: Vec<Option<f64>> = match &req.y {
            Some(y) => y.values.iter().copied().map(Some).collect(),
            None => vec![None],
        };
        let settings: Vec<(f64, Option<f64>, Value)> = y_values
            .iter()
            .flat_map(|&y| req.x.values.iter().map(move |&x| (x, y)))
            .map(|(x, y)| {
                report::with_param(&config.parameters, &req.x.component, &req.x.param, x)
                    .and_then(|p| match (y, &req.y) {
                        (Some(yv), Some(axis)) => {
                            report::with_param(&p, &axis.component, &axis.param, yv)
                        }
                        _ => Some(p),
                    })
                    .map(|p| (x, y, p))
                    .ok_or_else(|| AppError::BadRequest("no such setting".into()))
            })
            .collect::<AppResult<_>>()?;

        let judge = |(x, y, parameters): &(f64, Option<f64>, Value)| {
            let cell_config = StrategyConfig {
                parameters: parameters.clone(),
                ..config.clone()
            };
            match run_strategy(&candles, &cell_config, &financing) {
                Ok(trades) => {
                    let (from, to) = pipeline::span(&candles);
                    let stats = calculate_backtest_stats(&trades, from, to);
                    let mut stats_json = backtest_stats_to_json(&stats);
                    let (status, _) = evaluate_thresholds(
                        &mut stats_json,
                        &thresholds,
                        "backtest",
                        timeframe_class,
                    );
                    json!({
                        "x": x,
                        "y": y,
                        "total_return": stats.total_return,
                        "num_trades": stats.num_trades,
                        "t_stat": t_stat(&stats),
                        "passed": status == "passed",
                    })
                }
                Err(e) => json!({ "x": x, "y": y, "error": e.to_string() }),
            }
        };

        // Split over a few threads (not all cores, so the live feed keeps
        // headroom), keeping the cells in order.
        let per_thread = settings.len().div_ceil(WORKERS).max(1);
        let cells: Vec<Value> = std::thread::scope(|scope| {
            settings
                .chunks(per_thread)
                .map(|chunk| scope.spawn(|| chunk.iter().map(&judge).collect::<Vec<_>>()))
                .collect::<Vec<_>>()
                .into_iter()
                .zip(settings.chunks(per_thread))
                .flat_map(|(handle, chunk)| {
                    // A worker that panicked loses its chunk; its cells are
                    // reported as errors rather than silently missing.
                    handle.join().unwrap_or_else(|_| {
                        chunk
                            .iter()
                            .map(|(x, y, _)| json!({ "x": x, "y": y, "error": "crashed" }))
                            .collect()
                    })
                })
                .collect()
        });
        Ok(cells)
    })
    .await?;

    Ok(Json(json!({ "cells": cells })))
}

/// The pipeline's view of a strategy JSON: its instrument and timeframe.
pub(super) fn config_of(parameters: Value) -> AppResult<StrategyConfig> {
    let field = |key: &str| {
        parameters
            .get(key)
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| AppError::BadRequest(format!("strategy has no {key}")))
    };
    let instrument = field("instrument")?;
    let granularity = field("granularity")?
        .parse()
        .map_err(|e| AppError::BadRequest(format!("invalid granularity: {e}")))?;

    Ok(StrategyConfig {
        id: Uuid::nil(),
        instrument,
        granularity,
        strategy_type: "composite".to_string(),
        parameters,
    })
}

pub(super) async fn blocking<T, F>(work: F) -> AppResult<T>
where
    F: FnOnce() -> AppResult<T> + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(work)
        .await
        .map_err(|e| AppError::Internal(format!("report task failed: {e}")))?
}
