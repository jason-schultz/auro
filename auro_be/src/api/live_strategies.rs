use axum::extract::{Path, Query, State};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::error::{AppError, AppResult};
use crate::state::AppState;

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

pub async fn list_live_strategies(
    State(state): State<AppState>,
    Query(params): Query<ListParams>,
) -> AppResult<Json<Value>> {
    // Query 1: fetch live strategies (10 columns, well under sqlx tuple limit of 16)
    let rows = sqlx::query_as::<
        _,
        (
            Uuid,
            String,
            String,
            String,
            Value,
            bool,
            String,
            chrono::DateTime<chrono::Utc>,
            chrono::DateTime<chrono::Utc>,
            Option<Uuid>,
        ),
    >(
        r#"
        SELECT id, strategy_type, instrument, granularity, parameters,
               enabled, max_position_size, created_at, updated_at, backtest_run_id
        FROM live_strategies
        ORDER BY instrument, strategy_type
        "#,
    )
    .fetch_all(&state.db)
    .await
    .map_err(AppError::Database)?;

    // Collect backtest_run_ids that need stats
    let backtest_ids: Vec<Uuid> = rows.iter().filter_map(|r| r.9).collect();

    // Query 2: batch-fetch backtest stats for those IDs
    let mut stats_map: std::collections::HashMap<Uuid, Value> = std::collections::HashMap::new();
    if !backtest_ids.is_empty() {
        let stat_rows = sqlx::query_as::<_, (Uuid, f64, f64, f64, f64, i32, f64, f64)>(
            r#"
            SELECT id, total_return, win_rate, sharpe_ratio, max_drawdown,
                   num_trades, avg_win, avg_loss
            FROM backtest_runs
            WHERE id = ANY($1)
            "#,
        )
        .bind(&backtest_ids)
        .fetch_all(&state.db)
        .await
        .map_err(AppError::Database)?;

        for (id, total_return, win_rate, sharpe, drawdown, num_trades, avg_win, avg_loss) in
            stat_rows
        {
            stats_map.insert(
                id,
                json!({
                    "total_return": total_return,
                    "win_rate": win_rate,
                    "sharpe_ratio": sharpe,
                    "max_drawdown": drawdown,
                    "num_trades": num_trades,
                    "avg_win": avg_win,
                    "avg_loss": avg_loss,
                }),
            );
        }
    }

    let mut strategies: Vec<Value> = rows
        .iter()
        .map(
            |(
                id,
                stype,
                instrument,
                granularity,
                params,
                enabled,
                max_size,
                created,
                updated,
                backtest_run_id,
            )| {
                let mut obj = json!({
                    "id": id,
                    "strategy_type": stype,
                    "instrument": instrument,
                    "granularity": granularity,
                    "parameters": params,
                    "enabled": enabled,
                    "max_position_size": max_size,
                    "created_at": created,
                    "updated_at": updated,
                    "backtest_run_id": backtest_run_id,
                });

                if let Some(bt_id) = backtest_run_id {
                    if let Some(stats) = stats_map.get(bt_id) {
                        obj["backtest_stats"] = stats.clone();
                    }
                }

                obj
            },
        )
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

    let result = sqlx::query(
        r#"
        INSERT INTO live_strategies (id, strategy_type, instrument, granularity, parameters, enabled, max_position_size)
        VALUES ($1, $2, $3, $4, $5, false, $6)
        "#,
    )
    .bind(id)
    .bind(&payload.strategy_type)
    .bind(&payload.instrument)
    .bind(&payload.granularity)
    .bind(&payload.parameters)
    .bind(&max_size)
    .execute(&state.db)
    .await;

    match result {
        Ok(_) => {
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
    let row = sqlx::query_as::<_, (Uuid, String, String, String, Value, bool, String, chrono::DateTime<chrono::Utc>, chrono::DateTime<chrono::Utc>)>(
        "SELECT id, strategy_type, instrument, granularity, parameters, enabled, max_position_size, created_at, updated_at FROM live_strategies WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(&state.db)
    .await
    .map_err(AppError::Database)?;

    match row {
        Some((id, stype, instrument, granularity, params, enabled, max_size, created, updated)) => {
            // Also fetch live trades for this strategy
            let trades = sqlx::query_as::<
                _,
                (
                    Uuid,
                    Option<String>,
                    String,
                    String,
                    String,
                    Option<f64>,
                    Option<f64>,
                    chrono::DateTime<chrono::Utc>,
                    Option<chrono::DateTime<chrono::Utc>>,
                    Option<f64>,
                    Option<f64>,
                    Option<String>,
                    Option<String>,
                    String,
                ),
            >(
                r#"
                SELECT id, oanda_trade_id, instrument, direction, units,
                       entry_price, exit_price, entry_time, exit_time,
                       stop_loss_price, take_profit_price, entry_reason, exit_reason, status
                FROM live_trades
                WHERE live_strategy_id = $1
                ORDER BY entry_time DESC
                LIMIT 50
                "#,
            )
            .bind(id)
            .fetch_all(&state.db)
            .await
            .map_err(AppError::Database)?;

            let trade_list: Vec<Value> = trades
                .iter()
                .map(
                    |(
                        tid,
                        oanda_id,
                        inst,
                        dir,
                        units,
                        entry_p,
                        exit_p,
                        entry_t,
                        exit_t,
                        sl,
                        tp,
                        entry_r,
                        exit_r,
                        status,
                    )| {
                        json!({
                            "id": tid,
                            "oanda_trade_id": oanda_id,
                            "instrument": inst,
                            "direction": dir,
                            "units": units,
                            "entry_price": entry_p,
                            "exit_price": exit_p,
                            "entry_time": entry_t,
                            "exit_time": exit_t,
                            "stop_loss_price": sl,
                            "take_profit_price": tp,
                            "entry_reason": entry_r,
                            "exit_reason": exit_r,
                            "status": status,
                        })
                    },
                )
                .collect();

            Ok(Json(json!({
                "id": id,
                "strategy_type": stype,
                "instrument": instrument,
                "granularity": granularity,
                "parameters": params,
                "enabled": enabled,
                "max_position_size": max_size,
                "created_at": created,
                "updated_at": updated,
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

    let result = sqlx::query(
        r#"
        UPDATE live_strategies
        SET strategy_type = $1, instrument = $2, granularity = $3, parameters = $4,
            max_position_size = $5, updated_at = NOW()
        WHERE id = $6
        "#,
    )
    .bind(&payload.strategy_type)
    .bind(&payload.instrument)
    .bind(&payload.granularity)
    .bind(&payload.parameters)
    .bind(&max_size)
    .bind(id)
    .execute(&state.db)
    .await
    .map_err(AppError::Database)?;

    if result.rows_affected() == 0 {
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
    let row = sqlx::query_as::<_, (bool, String, String)>(
        "UPDATE live_strategies SET enabled = NOT enabled, updated_at = NOW() WHERE id = $1 RETURNING enabled, strategy_type, instrument",
    )
    .bind(id)
    .fetch_optional(&state.db)
    .await
    .map_err(AppError::Database)?;

    match row {
        Some((enabled, stype, instrument)) => {
            tracing::info!(
                "Strategy {} ({} on {}) {}",
                id,
                stype,
                instrument,
                if enabled { "ENABLED" } else { "DISABLED" }
            );
            Ok(Json(json!({ "id": id, "enabled": enabled })))
        }
        None => Err(AppError::NotFound("Strategy not found".into())),
    }
}

pub async fn delete_live_strategy(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    // Check if there are open trades
    let open_count: (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM live_trades WHERE live_strategy_id = $1 AND status = 'open'",
    )
    .bind(id)
    .fetch_one(&state.db)
    .await
    .map_err(AppError::Database)?;

    if open_count.0 > 0 {
        return Err(AppError::BadRequest(
            "Cannot delete strategy with open trades. Close all positions first.".into(),
        ));
    }

    let result = sqlx::query("DELETE FROM live_strategies WHERE id = $1")
        .bind(id)
        .execute(&state.db)
        .await
        .map_err(AppError::Database)?;

    if result.rows_affected() == 0 {
        return Err(AppError::NotFound("Strategy not found".into()));
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
    let row = sqlx::query_as::<_, (String, String, String, Value)>(
        "SELECT strategy_type, instrument, granularity, parameters FROM backtest_runs WHERE id = $1",
    )
    .bind(backtest_id)
    .fetch_optional(&state.db)
    .await
    .map_err(AppError::Database)?;

    match row {
        Some((strategy_type, instrument, granularity, parameters)) => {
            let id = Uuid::new_v4();
            let max_size = payload
                .max_position_size
                .unwrap_or_else(|| "1000".to_string());

            let result = sqlx::query(
                r#"
                INSERT INTO live_strategies (id, strategy_type, instrument, granularity, parameters, enabled, max_position_size, backtest_run_id)
                VALUES ($1, $2, $3, $4, $5, false, $6, $7)
                "#,
            )
            .bind(id)
            .bind(&strategy_type)
            .bind(&instrument)
            .bind(&granularity)
            .bind(&parameters)
            .bind(&max_size)
            .bind(backtest_id)
            .execute(&state.db)
            .await;

            match result {
                Ok(_) => {
                    tracing::info!(
                        "Deployed backtest {} as live strategy {}: {} on {} (disabled)",
                        backtest_id,
                        id,
                        strategy_type,
                        instrument
                    );

                    Ok(Json(json!({
                        "id": id,
                        "strategy_type": strategy_type,
                        "instrument": instrument,
                        "granularity": granularity,
                        "parameters": parameters,
                        "enabled": false,
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
        return db_err.code().map_or(false, |code| code == "23505");
    }
    false
}

// Trading config endpoints
pub async fn get_trading_config(State(state): State<AppState>) -> AppResult<Json<Value>> {
    let rows =
        sqlx::query_as::<_, (String, Value)>("SELECT key, value FROM trading_config ORDER BY key")
            .fetch_all(&state.db)
            .await
            .map_err(AppError::Database)?;

    let config: serde_json::Map<String, Value> = rows.into_iter().map(|(k, v)| (k, v)).collect();

    Ok(Json(json!({ "config": config })))
}

pub async fn update_trading_config(
    State(state): State<AppState>,
    Json(payload): Json<Value>,
) -> AppResult<Json<Value>> {
    if let Some(obj) = payload.as_object() {
        for (key, value) in obj {
            sqlx::query(
                "INSERT INTO trading_config (key, value, updated_at) VALUES ($1, $2, NOW()) ON CONFLICT (key) DO UPDATE SET value = $2, updated_at = NOW()"
            )
            .bind(key)
            .bind(value)
            .execute(&state.db)
            .await
            .map_err(AppError::Database)?;
        }
    }

    tracing::info!("Trading config updated: {:?}", payload);

    get_trading_config(State(state)).await
}

// Live trades endpoint
pub async fn get_live_trades(
    State(state): State<AppState>,
    Query(params): Query<LiveTradesParams>,
) -> AppResult<Json<Value>> {
    let status = params.status.unwrap_or_else(|| "all".to_string());
    let limit = params.limit.unwrap_or(50);

    let rows = if status == "all" {
        sqlx::query_as::<
            _,
            (
                Uuid,
                Option<Uuid>,
                Option<String>,
                String,
                String,
                String,
                Option<f64>,
                Option<f64>,
                chrono::DateTime<chrono::Utc>,
                Option<chrono::DateTime<chrono::Utc>>,
                Option<f64>,
                Option<String>,
                Option<String>,
                String,
            ),
        >(
            r#"
            SELECT id, live_strategy_id, oanda_trade_id, instrument, direction, units,
                   entry_price, exit_price, entry_time, exit_time,
                   pnl_percent, entry_reason, exit_reason, status
            FROM live_trades
            ORDER BY entry_time DESC
            LIMIT $1
            "#,
        )
        .bind(limit)
        .fetch_all(&state.db)
        .await
        .map_err(AppError::Database)?
    } else {
        sqlx::query_as::<
            _,
            (
                Uuid,
                Option<Uuid>,
                Option<String>,
                String,
                String,
                String,
                Option<f64>,
                Option<f64>,
                chrono::DateTime<chrono::Utc>,
                Option<chrono::DateTime<chrono::Utc>>,
                Option<f64>,
                Option<String>,
                Option<String>,
                String,
            ),
        >(
            r#"
            SELECT id, live_strategy_id, oanda_trade_id, instrument, direction, units,
                   entry_price, exit_price, entry_time, exit_time,
                   pnl_percent, entry_reason, exit_reason, status
            FROM live_trades
            WHERE status = $1
            ORDER BY entry_time DESC
            LIMIT $2
            "#,
        )
        .bind(&status)
        .bind(limit)
        .fetch_all(&state.db)
        .await
        .map_err(AppError::Database)?
    };

    let trades: Vec<Value> = rows
        .iter()
        .map(
            |(
                id,
                strat_id,
                oanda_id,
                inst,
                dir,
                units,
                entry_p,
                exit_p,
                entry_t,
                exit_t,
                pnl,
                entry_r,
                exit_r,
                status,
            )| {
                json!({
                    "id": id,
                    "live_strategy_id": strat_id,
                    "oanda_trade_id": oanda_id,
                    "instrument": inst,
                    "direction": dir,
                    "units": units,
                    "entry_price": entry_p,
                    "exit_price": exit_p,
                    "entry_time": entry_t,
                    "exit_time": exit_t,
                    "pnl_percent": pnl,
                    "entry_reason": entry_r,
                    "exit_reason": exit_r,
                    "status": status,
                })
            },
        )
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
