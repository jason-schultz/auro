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
use crate::engine::live::sizing::{MAX_NOTIONAL_OVERRIDE_PCT, MAX_RISK_PCT};
use crate::engine::strategy::{SizingConfig, Strategy};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

/// Aggregate closed-trade stats for the given strategy ids. Returns a map keyed by
/// strategy id; strategies with no closed trades are absent from the map.
async fn live_stats_by_strategy(
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
}

/// Largest number a block setting may hold. Periods are bar counts; one far
/// past any history overflows the indicator arithmetic.
const MAX_BLOCK_SETTING: f64 = 100_000.0;

/// The first block setting past `MAX_BLOCK_SETTING`, as (component, param, value).
fn oversized_setting(parameters: &Value) -> Option<(String, String, f64)> {
    parameters["components"]
        .as_object()?
        .iter()
        .find_map(|(name, component)| {
            component["params"]
                .as_object()?
                .iter()
                .find_map(|(param, value)| {
                    value
                        .as_f64()
                        .filter(|v| v.abs() > MAX_BLOCK_SETTING)
                        .map(|v| (name.clone(), param.clone(), v))
                })
        })
}

/// Reject configs the evaluator could never trade: the parameters must be a
/// composite strategy for this instrument/granularity, sized within the
/// risk-per-trade ceiling.
fn validate_parameters(payload: &CreateLiveStrategy) -> AppResult<()> {
    let strategy: Strategy = serde_json::from_value(payload.parameters.clone())
        .map_err(|e| AppError::BadRequest(format!("invalid composite parameters: {e}")))?;

    if strategy.instrument != payload.instrument
        || strategy.granularity.as_str() != payload.granularity
    {
        return Err(AppError::BadRequest(format!(
            "parameters are for {} {}, row is {} {}",
            strategy.instrument, strategy.granularity, payload.instrument, payload.granularity
        )));
    }

    if let Some((component, param, value)) = oversized_setting(&payload.parameters) {
        return Err(AppError::BadRequest(format!(
            "{component}.{param} = {value} is out of range (at most {MAX_BLOCK_SETTING})"
        )));
    }

    let SizingConfig::RiskPct {
        pct,
        max_notional_pct,
    } = strategy.sizing;
    if !(pct > 0.0 && pct <= MAX_RISK_PCT) {
        return Err(AppError::BadRequest(format!(
            "sizing.RiskPct.pct must be in (0, {MAX_RISK_PCT}], got {pct}"
        )));
    }
    if let Some(cap) = max_notional_pct {
        if !(cap > 0.0 && cap <= MAX_NOTIONAL_OVERRIDE_PCT) {
            return Err(AppError::BadRequest(format!(
                "sizing.RiskPct.max_notional_pct must be in (0, {MAX_NOTIONAL_OVERRIDE_PCT}], got {cap}"
            )));
        }
    }

    Ok(())
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

    // Query 2a: batch-fetch live aggregate stats for the strategies we have
    let strategy_ids: Vec<Uuid> = rows.iter().map(|r| r.id).collect();
    let live_stats_map = live_stats_by_strategy(&state.db, &strategy_ids)
        .await
        .map_err(AppError::Database)?;

    // Pipeline stats from strategy_configs + strategy_evaluations matched by
    // (instrument, strategy_type, parameters). DISTINCT ON picks the
    // highest-scoring config when multiple pipeline runs share the same params.
    let mut pipeline_stats_map: HashMap<Uuid, Value> = HashMap::new();
    if !strategy_ids.is_empty() {
        let pipeline_rows =
            live_strategies_repo::fetch_pipeline_strategy_stats(&state.db, &strategy_ids)
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
            let mut obj = json!({
                "id": row.id,
                "strategy_type": row.strategy_type,
                "instrument": row.instrument,
                "granularity": row.granularity,
                "parameters": row.parameters,
                "enabled": row.enabled,
                "curator_mode": row.curator_mode,
                "created_at": row.created_at,
                "updated_at": row.updated_at,
                "source": "pipeline",
            });

            if let Some(pipeline) = pipeline_stats_map.get(&row.id) {
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
    validate_parameters(&payload)?;
    let id = Uuid::new_v4();

    let result = live_strategies_repo::insert_live_strategy(
        &state.db,
        id,
        &payload.strategy_type,
        &payload.instrument,
        &payload.granularity,
        &payload.parameters,
    )
    .await;

    match result {
        Ok(_) => {
            if !instrument_buffers_needed(&state.db, &payload.instrument, Some(id)).await? {
                load_instrument_buffers(&state, &payload.instrument).await?;
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
    validate_parameters(&payload)?;

    // Moving a strategy to another instrument or timeframe while it holds a
    // trade would orphan that trade: its exits run on the strategy's key.
    let open_count = live_queries::open_trade_count_for_strategy(&state.db, id)
        .await
        .map_err(AppError::Database)?;
    if open_count > 0 {
        let current = live_strategies_repo::get_live_strategy_by_id(&state.db, id)
            .await
            .map_err(AppError::Database)?;
        if let Some(current) = current {
            if current.instrument != payload.instrument
                || current.granularity != payload.granularity
            {
                return Err(AppError::BadRequest(format!(
                    "strategy holds {open_count} open trade(s); its instrument and timeframe can't change until they close"
                )));
            }
        }
    }

    let rows_affected = live_strategies_repo::update_live_strategy(
        &state.db,
        id,
        &payload.strategy_type,
        &payload.instrument,
        &payload.granularity,
        &payload.parameters,
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
    // All keys or none: a half-applied update would leave settings that
    // were meant to change together out of step.
    if let Some(obj) = payload.as_object() {
        let mut tx = state.db.begin().await.map_err(AppError::Database)?;
        for (key, value) in obj {
            live_strategies_repo::upsert_trading_config(&mut *tx, key, value)
                .await
                .map_err(AppError::Database)?;
        }
        tx.commit().await.map_err(AppError::Database)?;
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
        })
    });

    let live_aggregate = match row.live_strategy_id {
        Some(sid) => {
            let mut map = live_stats_by_strategy(&state.db, &[sid])
                .await
                .map_err(AppError::Database)?;
            map.remove(&sid)
        }
        None => None,
    };

    Ok(Json(json!({
        "trade": trade,
        "strategy": strategy,
        "live_aggregate": live_aggregate,
    })))
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_block_setting_far_past_any_history_is_refused() {
        let ok = serde_json::json!({"components": {"r": {"type": "RsiReversion", "params": {"rsi_period": 2}}}});
        assert!(super::oversized_setting(&ok).is_none());

        let huge = serde_json::json!({"components": {"m": {"type": "MaFilter", "params": {"period": 1e12}}}});
        let (component, param, _) = super::oversized_setting(&huge).unwrap();
        assert_eq!((component.as_str(), param.as_str()), ("m", "period"));
    }
}
