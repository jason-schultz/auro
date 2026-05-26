use axum::extract::{Path, Query, State};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::PgPool;
use std::collections::HashMap;
use uuid::Uuid;

use crate::db::repositories::{
    live_queries, live_strategies as live_strategies_repo, live_trades as live_trades_repo,
};
use crate::engine::live::prefill::{load_instrument_buffers, unload_instrument_buffers};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

/// Aggregate closed-trade stats for the given strategy ids. Returns a map keyed by
/// strategy id; strategies with no closed trades are absent from the map.
async fn fetch_live_aggregates(
    pool: &PgPool,
    strategy_ids: &[Uuid],
) -> Result<HashMap<Uuid, Value>, sqlx::Error> {
    let rows = live_trades_repo::fetch_live_aggregates(pool, strategy_ids).await?;

    let map = rows
        .into_iter()
        .map(|r| {
            let win_rate = if r.num_trades > 0 {
                r.wins as f64 / r.num_trades as f64
            } else {
                0.0
            };
            (
                r.strategy_id,
                json!({
                    "num_trades": r.num_trades,
                    "wins": r.wins,
                    "losses": r.losses,
                    "win_rate": win_rate,
                    "total_return": r.total_return,
                    "avg_win": r.avg_win,
                    "avg_loss": r.avg_loss,
                }),
            )
        })
        .collect();

    Ok(map)
}

async fn instrument_buffers_needed(
    pool: &PgPool,
    instrument: &str,
    exclude_strategy_id: Option<Uuid>,
) -> AppResult<bool> {
    // Any other strategy row on this instrument?
    let strategy_count = live_queries::strategy_count_for_instrument_excluding(
        pool,
        instrument,
        exclude_strategy_id,
    )
    .await
    .map_err(AppError::Database)?;

    if strategy_count > 0 {
        return Ok(true);
    }

    // Any open position on this instrument?
    let open_count = live_queries::open_trade_count_for_instrument(pool, instrument)
        .await
        .map_err(AppError::Database)?;

    Ok(open_count > 0)
}

#[derive(Deserialize)]
pub struct CreateLiveStrategy {
    pub strategy_type: String,
    pub instrument: String,
    pub granularity: String,
    pub parameters: Value,
    pub max_position_size: Option<String>,
}

#[derive(Deserialize)]
pub struct ListParams {
    pub instrument: Option<String>,
    pub enabled: Option<bool>,
}

pub async fn debug_positions(State(state): State<AppState>) -> AppResult<Json<Value>> {
    let positions = state.live.open_positions.read().await;
    let dump: Vec<_> = positions
        .values()
        .map(|p| {
            json!({
                "strategy_id": p.strategy_id,
                "trade_id": p.trade_id,
                "instrument": p.instrument,
                "direction": p.direction,
                "entry_price": p.entry_price,
            })
        })
        .collect();
    Ok(Json(json!({"count": dump.len(), "positions": dump})))
}

pub async fn debug_buffers(State(state): State<AppState>) -> AppResult<Json<Value>> {
    let buffers = state.live.buffers.read().await;
    let dump: Vec<_> = buffers
        .iter()
        .map(|((instrument, granularity), buffer)| {
            json!({
                "instrument": instrument,
                "granularity": granularity,
                "closes": buffer.closes(),
                "current_mid": buffer.current_mid,
                "last_close_time": buffer.candles.last().map(|c| c.time),
            })
        })
        .collect();
    Ok(Json(json!({"count": dump.len(), "buffers": dump})))
}

pub async fn list_live_strategies(
    State(state): State<AppState>,
    Query(params): Query<ListParams>,
) -> AppResult<Json<Value>> {
    let rows = live_strategies_repo::list_live_strategies(&state.db)
        .await
        .map_err(AppError::Database)?;

    // Collect backtest_run_ids that need stats
    let backtest_ids: Vec<Uuid> = rows.iter().filter_map(|r| r.backtest_run_id).collect();

    // Query 2a: batch-fetch live aggregate stats for the strategies we have
    let strategy_ids: Vec<Uuid> = rows.iter().map(|r| r.id).collect();
    let live_stats_map = fetch_live_aggregates(&state.db, &strategy_ids)
        .await
        .map_err(AppError::Database)?;

    // Query 2: batch-fetch grid-search backtest stats for strategies that have a backtest_run_id
    let mut stats_map: HashMap<Uuid, Value> = HashMap::new();
    if !backtest_ids.is_empty() {
        let stat_rows = live_strategies_repo::fetch_backtest_run_stats(&state.db, &backtest_ids)
            .await
            .map_err(AppError::Database)?;

        for row in stat_rows {
            stats_map.insert(
                row.id,
                json!({
                    "total_return": row.total_return,
                    "win_rate": row.win_rate,
                    "sharpe_ratio": row.sharpe_ratio,
                    "max_drawdown": row.max_drawdown,
                    "num_trades": row.num_trades,
                    "avg_win": row.avg_win,
                    "avg_loss": row.avg_loss,
                }),
            );
        }
    }

    // Query 3: for pipeline strategies (no backtest_run_id), look up stats from
    // strategy_configs + strategy_evaluations matched by (instrument, strategy_type, parameters).
    // DISTINCT ON picks the highest-scoring config when multiple pipeline runs share the same params.
    let pipeline_ids: Vec<Uuid> = rows
        .iter()
        .filter(|r| r.backtest_run_id.is_none())
        .map(|r| r.id)
        .collect();
    let mut pipeline_stats_map: HashMap<Uuid, Value> = HashMap::new();
    if !pipeline_ids.is_empty() {
        let pipeline_rows =
            live_strategies_repo::fetch_pipeline_strategy_stats(&state.db, &pipeline_ids)
                .await
                .map_err(AppError::Database)?;

        for row in pipeline_rows {
            let backtest_stats = row.bt_stats.as_ref().map(|b| {
                json!({
                    "sharpe_ratio": b["sharpe"],
                    "win_rate":     b["win_rate"],
                    "num_trades":   b["num_trades"],
                    "max_drawdown": b["max_drawdown"],
                    "total_return": b["total_return"],
                    "avg_win":      null,
                    "avg_loss":     null,
                })
            });

            let oos_stats = row.wf_stats.as_ref().map(|w| {
                json!({
                    "oos_sharpe":     w["oos_sharpe"],
                    "oos_num_trades": w["oos_num_trades"],
                    "oos_return":     w["oos_return"],
                    "sharpe_retention": w["sharpe_retention"],
                })
            });

            pipeline_stats_map.insert(
                row.id,
                json!({
                    "source":         row.source,
                    "pipeline_score": row.score,
                    "backtest_stats": backtest_stats,
                    "oos_stats":      oos_stats,
                }),
            );
        }
    }

    // Query 4: latest k-fold validation per strategy (if any). We take the most
    // recent row per live_strategy_id; older rows are kept as history but the UI
    // shows the latest.
    let mut kfold_map: HashMap<Uuid, Value> = HashMap::new();
    if !strategy_ids.is_empty() {
        let kfold_rows = live_strategies_repo::fetch_latest_kfold_stats(&state.db, &strategy_ids)
            .await
            .map_err(AppError::Database)?;

        for row in kfold_rows {
            kfold_map.insert(
                row.live_strategy_id,
                json!({
                    "fold_count": row.fold_count,
                    "pass_count": row.pass_count,
                    "pass_rate": row.pass_rate,
                    "median_sharpe": row.median_sharpe,
                }),
            );
        }
    }

    let mut strategies: Vec<Value> = rows
        .iter()
        .map(|row| {
            // Strategies with a backtest_run_id came from the grid-search / Backtests page.
            // Everything else came through the pipeline (Ollama, evo, manual promote).
            let source = if row.backtest_run_id.is_some() {
                "grid_search"
            } else {
                "pipeline"
            };

            let mut obj = json!({
                "id": row.id,
                "strategy_type": row.strategy_type,
                "instrument": row.instrument,
                "granularity": row.granularity,
                "parameters": row.parameters,
                "enabled": row.enabled,
                "curator_mode": row.curator_mode,
                "max_position_size": row.max_position_size,
                "created_at": row.created_at,
                "updated_at": row.updated_at,
                "backtest_run_id": row.backtest_run_id,
                "source": source,
            });

            if let Some(bt_id) = row.backtest_run_id {
                if let Some(stats) = stats_map.get(&bt_id) {
                    obj["backtest_stats"] = stats.clone();
                }
            } else if let Some(pipeline) = pipeline_stats_map.get(&row.id) {
                // Refine source from the strategy_config if available (e.g. "evolution")
                obj["source"] = pipeline["source"].clone();
                obj["pipeline_score"] = pipeline["pipeline_score"].clone();
                obj["backtest_stats"] = pipeline["backtest_stats"].clone();
                obj["oos_stats"] = pipeline["oos_stats"].clone();
            }

            if let Some(live) = live_stats_map.get(&row.id) {
                obj["live_stats"] = live.clone();
            }

            if let Some(kfold) = kfold_map.get(&row.id) {
                obj["kfold_stats"] = kfold.clone();
            }

            obj
        })
        .collect();

    // Filter in application if params provided
    if let Some(ref inst) = params.instrument {
        strategies.retain(|s| s["instrument"].as_str() == Some(inst.as_str()));
    }
    if let Some(enabled) = params.enabled {
        strategies.retain(|s| s["enabled"].as_bool() == Some(enabled));
    }

    Ok(Json(json!({
        "strategies": strategies,
        "count": strategies.len(),
    })))
}

pub async fn create_live_strategy(
    State(state): State<AppState>,
    Json(payload): Json<CreateLiveStrategy>,
) -> AppResult<Json<Value>> {
    let id = Uuid::new_v4();
    let max_size = payload
        .max_position_size
        .unwrap_or_else(|| "1000".to_string());

    let result = live_strategies_repo::insert_live_strategy(
        &state.db,
        id,
        &payload.strategy_type,
        &payload.instrument,
        &payload.granularity,
        &payload.parameters,
        &max_size,
    )
    .await;

    match result {
        Ok(_) => {
            if !instrument_buffers_needed(&state.db, &payload.instrument, Some(id)).await? {
                load_instrument_buffers(&state, &payload.instrument)
                    .await
                    .map_err(|e| {
                        AppError::Internal(format!(
                            "Failed to load buffers for {} after creating strategy {}: {}",
                            payload.instrument, id, e
                        ))
                    })?;
            }

            tracing::info!(
                "Created live strategy: {} {} on {} (disabled)",
                payload.strategy_type,
                payload.instrument,
                payload.granularity
            );

            Ok(Json(json!({
                "id": id,
                "strategy_type": payload.strategy_type,
                "instrument": payload.instrument,
                "granularity": payload.granularity,
                "parameters": payload.parameters,
                "enabled": false,
                "curator_mode": "auto",
                "max_position_size": max_size,
            })))
        }
        Err(e) => {
            if is_unique_violation(&e) {
                Err(AppError::Conflict(
                    "A strategy with these parameters already exists for this instrument.".into(),
                ))
            } else {
                Err(AppError::Database(e))
            }
        }
    }
}

pub async fn get_live_strategy(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let row = live_strategies_repo::get_live_strategy_by_id(&state.db, id)
        .await
        .map_err(AppError::Database)?;

    match row {
        Some(row) => {
            let trades = live_trades_repo::list_recent_for_strategy(&state.db, row.id, 50)
                .await
                .map_err(AppError::Database)?;

            let trade_list: Vec<Value> = trades
                .iter()
                .map(|trade| {
                    json!({
                        "id": trade.id,
                        "oanda_trade_id": trade.oanda_trade_id,
                        "instrument": trade.instrument,
                        "direction": trade.direction,
                        "units": trade.units,
                        "entry_price": trade.entry_price,
                        "exit_price": trade.exit_price,
                        "entry_time": trade.entry_time,
                        "exit_time": trade.exit_time,
                        "stop_loss_price": trade.stop_loss_price,
                        "take_profit_price": trade.take_profit_price,
                        "entry_reason": trade.entry_reason,
                        "exit_reason": trade.exit_reason,
                        "status": trade.status,
                    })
                })
                .collect();

            Ok(Json(json!({
                "id": row.id,
                "strategy_type": row.strategy_type,
                "instrument": row.instrument,
                "granularity": row.granularity,
                "parameters": row.parameters,
                "enabled": row.enabled,
                "curator_mode": row.curator_mode,
                "max_position_size": row.max_position_size,
                "created_at": row.created_at,
                "updated_at": row.updated_at,
                "trades": trade_list,
            })))
        }
        None => Err(AppError::NotFound("Strategy not found".into())),
    }
}

pub async fn update_live_strategy(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(payload): Json<CreateLiveStrategy>,
) -> AppResult<Json<Value>> {
    let max_size = payload
        .max_position_size
        .unwrap_or_else(|| "1000".to_string());

    let rows_affected = live_strategies_repo::update_live_strategy(
        &state.db,
        id,
        &payload.strategy_type,
        &payload.instrument,
        &payload.granularity,
        &payload.parameters,
        &max_size,
    )
    .await
    .map_err(AppError::Database)?;

    if rows_affected == 0 {
        return Err(AppError::NotFound("Strategy not found".into()));
    }

    tracing::info!("Updated live strategy {}", id);

    Ok(Json(json!({
        "id": id,
        "strategy_type": payload.strategy_type,
        "instrument": payload.instrument,
        "granularity": payload.granularity,
        "parameters": payload.parameters,
        "max_position_size": max_size,
    })))
}

pub async fn toggle_live_strategy(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let row = live_strategies_repo::toggle_live_strategy(&state.db, id)
        .await
        .map_err(AppError::Database)?;

    match row {
        Some(row) => {
            tracing::info!(
                "Strategy {} ({} on {}) {} with curator_mode={}",
                id,
                row.strategy_type,
                row.instrument,
                if row.enabled { "ENABLED" } else { "DISABLED" },
                row.curator_mode
            );
            Ok(Json(
                json!({ "id": id, "enabled": row.enabled, "curator_mode": row.curator_mode }),
            ))
        }
        None => Err(AppError::NotFound("Strategy not found".into())),
    }
}

pub async fn reset_live_strategy_curator_auto(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let row = live_strategies_repo::set_live_strategy_curator_auto(&state.db, id)
        .await
        .map_err(AppError::Database)?;

    match row {
        Some(row) => {
            tracing::info!(
                "Strategy {} ({} on {}) set to curator_mode=auto (enabled={})",
                id,
                row.strategy_type,
                row.instrument,
                row.enabled
            );

            Ok(Json(
                json!({ "id": id, "enabled": row.enabled, "curator_mode": row.curator_mode }),
            ))
        }
        None => Err(AppError::NotFound("Strategy not found".into())),
    }
}

pub async fn delete_live_strategy(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    // Check if there are open trades
    let open_count = live_queries::open_trade_count_for_strategy(&state.db, id)
        .await
        .map_err(AppError::Database)?;

    if open_count > 0 {
        return Err(AppError::BadRequest(
            "Cannot delete strategy with open trades. Close all positions first.".into(),
        ));
    }

    let row = live_strategies_repo::delete_live_strategy_returning_instrument(&state.db, id)
        .await
        .map_err(AppError::Database)?;

    let Some(instrument) = row else {
        return Err(AppError::NotFound("Strategy not found".into()));
    };

    if !instrument_buffers_needed(&state.db, &instrument, Some(id)).await? {
        unload_instrument_buffers(&state, &instrument).await;
    }

    tracing::info!("Deleted live strategy {}", id);

    Ok(Json(json!({ "deleted": true })))
}

// Deploy a backtest result as a live strategy
pub async fn deploy_from_backtest(
    State(state): State<AppState>,
    Path(backtest_id): Path<Uuid>,
    Json(payload): Json<DeployParams>,
) -> AppResult<Json<Value>> {
    // Fetch the backtest run
    let row = live_strategies_repo::find_backtest_deploy_source(&state.db, backtest_id)
        .await
        .map_err(AppError::Database)?;

    match row {
        Some(row) => {
            let id = Uuid::new_v4();
            let max_size = payload
                .max_position_size
                .unwrap_or_else(|| "1000".to_string());

            let result = live_strategies_repo::insert_deployed_live_strategy(
                &state.db,
                id,
                &row.strategy_type,
                &row.instrument,
                &row.granularity,
                &row.parameters,
                &max_size,
                backtest_id,
            )
            .await;

            match result {
                Ok(_) => {
                    if !instrument_buffers_needed(&state.db, &row.instrument, Some(id)).await? {
                        load_instrument_buffers(&state, &row.instrument)
                            .await
                            .map_err(|e| {
                                AppError::Internal(format!(
                                    "Failed to load buffers for {} after deploying strategy {}: {}",
                                    row.instrument, id, e
                                ))
                            })?;
                    }

                    tracing::info!(
                        "Deployed backtest {} as live strategy {}: {} on {} (disabled)",
                        backtest_id,
                        id,
                        row.strategy_type,
                        row.instrument
                    );

                    Ok(Json(json!({
                        "id": id,
                        "strategy_type": row.strategy_type,
                        "instrument": row.instrument,
                        "granularity": row.granularity,
                        "parameters": row.parameters,
                        "enabled": false,
                        "curator_mode": "auto",
                        "max_position_size": max_size,
                        "deployed_from": backtest_id,
                    })))
                }
                Err(e) => {
                    if is_unique_violation(&e) {
                        Err(AppError::Conflict(
                            "This strategy is already deployed for this instrument with these parameters.".into()
                        ))
                    } else {
                        Err(AppError::Database(e))
                    }
                }
            }
        }
        None => Err(AppError::NotFound("Backtest run not found".into())),
    }
}

#[derive(Deserialize)]
pub struct DeployParams {
    pub max_position_size: Option<String>,
}

/// Check if a sqlx error is a unique constraint violation (Postgres error code 23505)
fn is_unique_violation(e: &sqlx::Error) -> bool {
    if let sqlx::Error::Database(ref db_err) = e {
        return db_err.code().is_some_and(|code| code == "23505");
    }
    false
}

// Trading config endpoints
pub async fn get_trading_config(State(state): State<AppState>) -> AppResult<Json<Value>> {
    let rows = live_strategies_repo::list_trading_config(&state.db)
        .await
        .map_err(AppError::Database)?;

    let config: serde_json::Map<String, Value> =
        rows.into_iter().map(|row| (row.key, row.value)).collect();

    Ok(Json(json!({ "config": config })))
}

pub async fn update_trading_config(
    State(state): State<AppState>,
    Json(payload): Json<Value>,
) -> AppResult<Json<Value>> {
    if let Some(obj) = payload.as_object() {
        for (key, value) in obj {
            live_strategies_repo::upsert_trading_config(&state.db, key, value)
                .await
                .map_err(AppError::Database)?;
        }
    }

    tracing::info!("Trading config updated: {:?}", payload);

    get_trading_config(State(state)).await
}

pub async fn get_live_trades(
    State(state): State<AppState>,
    Query(params): Query<LiveTradesParams>,
) -> AppResult<Json<Value>> {
    let status = params.status.unwrap_or_else(|| "all".to_string());
    let limit = params.limit.unwrap_or(50);

    let rows = live_trades_repo::list_live_trades(
        &state.db,
        if status == "all" {
            None
        } else {
            Some(status.as_str())
        },
        limit,
    )
    .await
    .map_err(AppError::Database)?;

    let trades: Vec<Value> = rows
        .iter()
        .map(|row| {
            json!({
                "id": row.id,
                "live_strategy_id": row.live_strategy_id,
                "oanda_trade_id": row.oanda_trade_id,
                "instrument": row.instrument,
                "direction": row.direction,
                "units": row.units,
                "entry_price": row.entry_price,
                "exit_price": row.exit_price,
                "entry_time": row.entry_time,
                "exit_time": row.exit_time,
                "pnl_percent": row.pnl_percent,
                "entry_reason": row.entry_reason,
                "exit_reason": row.exit_reason,
                "status": row.status,
                "strategy_type": row.strategy_type,
                "strategy_parameters": row.parameters,
                "strategy_granularity": row.granularity,
                "indicators_at_entry": row.indicators_at_entry,
                "regime_at_entry": row.regime_at_entry,
                "mae_pct": row.mae_pct,
                "mfe_pct": row.mfe_pct,
                "stop_loss_state_at_close": row.stop_loss_state_at_close,
            })
        })
        .collect();

    Ok(Json(json!({
        "trades": trades,
        "count": trades.len(),
    })))
}

#[derive(Deserialize)]
pub struct LiveTradesParams {
    pub status: Option<String>,
    pub limit: Option<i64>,
}

pub async fn get_live_trade_detail(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let row = live_trades_repo::find_live_trade_detail(&state.db, id)
        .await
        .map_err(AppError::Database)?;

    let row = row.ok_or_else(|| AppError::NotFound(format!("Trade {} not found", id)))?;

    let trade = json!({
        "id": row.id,
        "oanda_trade_id": row.oanda_trade_id,
        "instrument": row.instrument,
        "direction": row.direction,
        "units": row.units,
        "entry_price": row.entry_price,
        "exit_price": row.exit_price,
        "entry_time": row.entry_time,
        "exit_time": row.exit_time,
        "pnl_percent": row.pnl_percent,
        "entry_reason": row.entry_reason,
        "exit_reason": row.exit_reason,
        "status": row.status,
        "indicators_at_entry": row.indicators_at_entry,
        "regime_at_entry": row.regime_at_entry,
        "stop_loss_state_at_close": row.stop_loss_state_at_close,
    });

    let strategy = row.live_strategy_id.map(|sid| {
        json!({
            "id": sid,
            "strategy_type": row.strategy_type,
            "parameters": row.parameters,
            "granularity": row.granularity,
            "enabled": row.enabled,
            "max_position_size": row.max_position_size,
            "backtest_run_id": row.backtest_run_id,
        })
    });

    let backtest = row.backtest_run_id.map(|bid| {
        json!({
            "id": bid,
            "strategy_name": row.bt_strategy_name,
            "total_return": row.bt_total_return,
            "win_rate": row.bt_win_rate,
            "sharpe_ratio": row.bt_sharpe_ratio,
            "max_drawdown": row.bt_max_drawdown,
            "num_trades": row.bt_num_trades,
            "avg_win": row.bt_avg_win,
            "avg_loss": row.bt_avg_loss,
        })
    });

    let live_aggregate = match row.live_strategy_id {
        Some(sid) => {
            let mut map = fetch_live_aggregates(&state.db, &[sid])
                .await
                .map_err(AppError::Database)?;
            map.remove(&sid)
        }
        None => None,
    };

    Ok(Json(json!({
        "trade": trade,
        "strategy": strategy,
        "backtest": backtest,
        "live_aggregate": live_aggregate,
    })))
}
