use axum::extract::{Path, Query, State};
use axum::Json;
use chrono::Duration;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::engine::aggregator::granularity_to_minutes;
use crate::engine::grid::{self};
use crate::error::AppResult;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct RunGridParams {
    pub instrument: Option<String>,
    pub timeframe: Option<String>,
    pub strategy: Option<String>,
}

#[derive(Deserialize)]
pub struct BacktestResultsParams {
    pub status: Option<String>,
    pub limit: Option<i64>,
    pub strategy_type: Option<String>,
    pub granularity: Option<String>,
    pub instrument: Option<String>,
}

#[derive(Deserialize)]
pub struct BackfillParams {
    pub instrument: String,
    pub granularity: Option<String>,
    pub days: Option<i64>,
}

pub async fn run_grid_search(
    State(state): State<AppState>,
    Query(params): Query<RunGridParams>,
) -> AppResult<Json<Value>> {
    let instrument = params.instrument.unwrap_or_else(|| "EUR_USD".to_string());
    let timeframe = params.timeframe.unwrap_or_else(|| "H1".to_string());
    let strategy = params
        .strategy
        .unwrap_or_else(|| "mean_reversion".to_string());

    let candles = grid::load_candles(&state.db, &instrument, &timeframe)
        .await
        .map_err(crate::error::AppError::Database)?;

    if candles.is_empty() {
        return Ok(Json(json!({
            "error": "No candle data found",
            "instrument": instrument,
            "timeframe": timeframe,
        })));
    }

    let start_time = std::time::Instant::now();

    let results = match strategy.as_str() {
        "trend_following" => {
            let config = grid::TrendGridConfig {
                instrument: instrument.clone(),
                granularity: timeframe.clone(),
                fast_periods: vec![5, 10, 15, 20, 25],
                slow_periods: vec![30, 40, 50, 60, 75, 100, 150],
                stop_losses: vec![-0.01, -0.02, -0.03, -0.04, -0.05],
                take_profits: vec![None, Some(0.02), Some(0.03), Some(0.05), Some(0.10)],
            };

            tracing::info!(
                "Starting trend following grid: {} combinations on {} ({}) with {} candles",
                config.total_combinations(),
                instrument,
                timeframe,
                candles.len()
            );

            grid::run_trend_grid(&candles, &config)
        }
        _ => {
            let config = grid::GridSearchConfig {
                instrument: instrument.clone(),
                granularity: timeframe.clone(),
                ma_periods: vec![10, 15, 20, 25, 30, 40, 50],
                entry_thresholds: vec![-0.002, -0.003, -0.005, -0.007, -0.01, -0.015, -0.02],
                exit_thresholds: vec![0.001, 0.002, 0.003, 0.005, 0.007, 0.01],
                stop_losses: vec![-0.005, -0.01, -0.015, -0.02, -0.03],
            };

            tracing::info!(
                "Starting mean reversion grid: {} combinations on {} ({}) with {} candles",
                config.total_combinations(),
                instrument,
                timeframe,
                candles.len()
            );

            grid::run_mean_grid(&candles, &config)
        }
    };

    let valid_count = results.iter().filter(|r| r.status == "valid").count();
    let verify_count = results.iter().filter(|r| r.status == "verify").count();
    let failed_count = results.iter().filter(|r| r.status == "failed").count();
    let end_time = std::time::Instant::now();

    let stored = grid::store_results(&state.db, &instrument, &timeframe, &results)
        .await
        .map_err(crate::error::AppError::Database)?;

    tracing::info!(
        "Grid search complete: {} valid, {} verify, {} failed. Stored {} runs.",
        valid_count,
        verify_count,
        failed_count,
        stored
    );

    Ok(Json(json!({
        "strategy": strategy,
        "instrument": instrument,
        "timeframe": timeframe,
        "candles_used": candles.len(),
        "results": {
            "valid": valid_count,
            "verify": verify_count,
            "failed": failed_count,
        },
        "stored": stored,
        "duration": (end_time - start_time).as_secs_f64() / 60.0,
    })))
}

pub async fn get_backtest_results(
    State(state): State<AppState>,
    Query(params): Query<BacktestResultsParams>,
) -> AppResult<Json<Value>> {
    let status_filter = params.status.unwrap_or_else(|| "valid".to_string());
    let limit = params.limit.unwrap_or(500);

    // Build query dynamically to avoid combinatorial explosion of if/else branches
    let mut query = String::from(
        "SELECT id, strategy_name, strategy_type, instrument, granularity,
                parameters, total_return, win_rate, sharpe_ratio, max_drawdown,
                num_trades, avg_win, avg_loss, status, reason_flagged, execution_duration_ms
         FROM backtest_runs
         WHERE status = $1",
    );

    let mut param_idx = 2;

    if params.strategy_type.is_some() {
        query.push_str(&format!(" AND strategy_type = ${}", param_idx));
        param_idx += 1;
    }
    if params.granularity.is_some() {
        query.push_str(&format!(" AND granularity = ${}", param_idx));
        param_idx += 1;
    }
    if params.instrument.is_some() {
        query.push_str(&format!(" AND instrument = ${}", param_idx));
        param_idx += 1;
    }

    query.push_str(&format!(" ORDER BY sharpe_ratio DESC LIMIT ${}", param_idx));

    // Use sqlx::query to build dynamically
    let mut q = sqlx::query(&query).bind(&status_filter);

    if let Some(ref stype) = params.strategy_type {
        q = q.bind(stype);
    }
    if let Some(ref gran) = params.granularity {
        q = q.bind(gran);
    }
    if let Some(ref inst) = params.instrument {
        q = q.bind(inst);
    }
    q = q.bind(limit);

    let rows = q
        .fetch_all(&state.db)
        .await
        .map_err(crate::error::AppError::Database)?;

    let results: Vec<Value> = rows
        .iter()
        .map(|row| {
            use sqlx::Row;
            json!({
                "id": row.get::<uuid::Uuid, _>("id"),
                "strategy_name": row.get::<String, _>("strategy_name"),
                "strategy_type": row.get::<String, _>("strategy_type"),
                "instrument": row.get::<String, _>("instrument"),
                "granularity": row.get::<String, _>("granularity"),
                "parameters": row.get::<serde_json::Value, _>("parameters"),
                "total_return": row.get::<f64, _>("total_return"),
                "win_rate": row.get::<f64, _>("win_rate"),
                "sharpe_ratio": row.get::<f64, _>("sharpe_ratio"),
                "max_drawdown": row.get::<f64, _>("max_drawdown"),
                "num_trades": row.get::<i32, _>("num_trades"),
                "avg_win": row.get::<f64, _>("avg_win"),
                "avg_loss": row.get::<f64, _>("avg_loss"),
                "status": row.get::<String, _>("status"),
                "reason_flagged": row.get::<Option<String>, _>("reason_flagged"),
                "execution_duration_ms": row.get::<i32, _>("execution_duration_ms"),
            })
        })
        .collect();

    Ok(Json(json!({
        "results": results,
        "count": results.len(),
        "status_filter": status_filter,
    })))
}

pub async fn backfill_historical(
    State(state): State<AppState>,
    Query(params): Query<BackfillParams>,
) -> AppResult<Json<Value>> {
    let instrument = params.instrument;
    let granularity = params.granularity.unwrap_or_else(|| "H1".to_string());
    let days = params.days.unwrap_or(365);

    tracing::info!(
        "Starting historical backfill: {} {} for {} days",
        instrument,
        granularity,
        days
    );

    let start = chrono::Utc::now() - Duration::days(days);
    let mut current_from = start.format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let mut total_count = 0;

    loop {
        let response = state
            .oanda
            .get_candles(
                &instrument,
                &granularity,
                Some(5000),
                Some(&current_from),
                None,
            )
            .await?;

        if response.candles.is_empty() {
            break;
        }

        let records: Vec<crate::oanda::models::CandleRecord> = response
            .candles
            .iter()
            .filter_map(|c| {
                let mid = c.mid.as_ref()?;
                let timestamp = chrono::DateTime::parse_from_rfc3339(&c.time)
                    .ok()?
                    .with_timezone(&chrono::Utc);

                Some(crate::oanda::models::CandleRecord {
                    instrument: instrument.clone(),
                    granularity: granularity.clone(),
                    timestamp,
                    open: mid.o.parse().ok()?,
                    high: mid.h.parse().ok()?,
                    low: mid.l.parse().ok()?,
                    close: mid.c.parse().ok()?,
                    volume: c.volume,
                    complete: c.complete,
                })
            })
            .collect();

        let count = crate::db::upsert_candles(&state.db, &records)
            .await
            .map_err(crate::error::AppError::Database)?;
        total_count += count;

        tracing::info!(
            "Backfilled {} candles for {} {} (total so far: {})",
            count,
            instrument,
            granularity,
            total_count
        );

        if response.candles.len() < 5000 {
            break;
        }

        if let Some(last) = records.last() {
            current_from = (last.timestamp
                + Duration::minutes(granularity_to_minutes(granularity.clone()) as i64))
            .format("%Y-%m-%dT%H:%M:%SZ")
            .to_string();
        } else {
            break;
        }
    }

    tracing::info!(
        "Historical backfill complete: {} total candles for {} {}",
        total_count,
        instrument,
        granularity
    );

    Ok(Json(json!({
        "instrument": instrument,
        "granularity": granularity,
        "days": days,
        "candles_stored": total_count,
    })))
}

pub async fn get_backtest_trades(
    State(state): State<AppState>,
    Path(id): Path<uuid::Uuid>,
) -> AppResult<Json<Value>> {
    let rows = sqlx::query_as::<
        _,
        (
            uuid::Uuid,
            f64,
            f64,
            chrono::DateTime<chrono::Utc>,
            chrono::DateTime<chrono::Utc>,
            f64,
            String,
            String,
            Option<serde_json::Value>,
        ),
    >(
        r#"
        SELECT id, entry_price, exit_price, entry_time, exit_time,
               pnl_percent, entry_reason, exit_reason, entry_details
        FROM backtest_trades
        WHERE backtest_run_id = $1
        ORDER BY entry_time ASC
        "#,
    )
    .bind(id)
    .fetch_all(&state.db)
    .await
    .map_err(crate::error::AppError::Database)?;

    let trades: Vec<Value> = rows
        .iter()
        .map(
            |(
                id,
                entry_price,
                exit_price,
                entry_time,
                exit_time,
                pnl_percent,
                entry_reason,
                exit_reason,
                entry_details,
            )| {
                json!({
                    "id": id,
                    "entry_price": entry_price,
                    "exit_price": exit_price,
                    "entry_time": entry_time,
                    "exit_time": exit_time,
                    "pnl_percent": pnl_percent,
                    "entry_reason": entry_reason,
                    "exit_reason": exit_reason,
                    "entry_details": entry_details,
                })
            },
        )
        .collect();

    Ok(Json(json!({
        "trades": trades,
        "count": trades.len(),
    })))
}
