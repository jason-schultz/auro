use axum::extract::{Path, Query, State};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::PgPool;
use std::collections::HashMap;
use uuid::Uuid;

use crate::error::{AppError, AppResult};
use crate::state::AppState;

#[derive(sqlx::FromRow)]
struct LiveAggregateRow {
    strategy_id: Uuid,
    num_trades: i64,
    wins: i64,
    losses: i64,
    total_return: f64,
    avg_win: f64,
    avg_loss: f64,
}

/// Aggregate closed-trade stats for the given strategy ids. Returns a map keyed by
/// strategy id; strategies with no closed trades are absent from the map.
async fn fetch_live_aggregates(
    pool: &PgPool,
    strategy_ids: &[Uuid],
) -> Result<HashMap<Uuid, Value>, sqlx::Error> {
    if strategy_ids.is_empty() {
        return Ok(HashMap::new());
    }

    let rows: Vec<LiveAggregateRow> = sqlx::query_as(
        r#"
        SELECT
            live_strategy_id AS strategy_id,
            COUNT(*)::BIGINT AS num_trades,
            COUNT(*) FILTER (WHERE pnl_percent > 0)::BIGINT AS wins,
            COUNT(*) FILTER (WHERE pnl_percent <= 0)::BIGINT AS losses,
            COALESCE(SUM(pnl_percent), 0)::FLOAT8 AS total_return,
            COALESCE(AVG(pnl_percent) FILTER (WHERE pnl_percent > 0), 0)::FLOAT8 AS avg_win,
            COALESCE(AVG(pnl_percent) FILTER (WHERE pnl_percent <= 0), 0)::FLOAT8 AS avg_loss
        FROM live_trades
        WHERE status = 'closed' AND live_strategy_id = ANY($1)
        GROUP BY live_strategy_id
        "#,
    )
    .bind(strategy_ids)
    .fetch_all(pool)
    .await?;

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

    // Query 2a: batch-fetch live aggregate stats for the strategies we have
    let strategy_ids: Vec<Uuid> = rows.iter().map(|r| r.0).collect();
    let live_stats_map = fetch_live_aggregates(&state.db, &strategy_ids)
        .await
        .map_err(AppError::Database)?;

    // Query 2: batch-fetch grid-search backtest stats for strategies that have a backtest_run_id
    let mut stats_map: HashMap<Uuid, Value> = HashMap::new();
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

    // Query 3: for pipeline strategies (no backtest_run_id), look up stats from
    // strategy_configs + strategy_evaluations matched by (instrument, strategy_type, parameters).
    // DISTINCT ON picks the highest-scoring config when multiple pipeline runs share the same params.
    let pipeline_ids: Vec<Uuid> = rows.iter().filter(|r| r.9.is_none()).map(|r| r.0).collect();
    let mut pipeline_stats_map: HashMap<Uuid, Value> = HashMap::new();
    if !pipeline_ids.is_empty() {
        let pipeline_rows =
            sqlx::query_as::<_, (Uuid, String, Option<f64>, Option<Value>, Option<Value>)>(
                r#"
            SELECT DISTINCT ON (ls.id)
                ls.id,
                sc.source,
                sc.score,
                bt.stats  AS bt_stats,
                wf.stats  AS wf_stats
            FROM live_strategies ls
            JOIN strategy_configs sc
                ON  sc.instrument    = ls.instrument
                AND sc.strategy_type = ls.strategy_type
                AND sc.parameters    = ls.parameters
            LEFT JOIN strategy_evaluations bt
                ON  bt.strategy_config_id = sc.id
                AND bt.stage   = 'backtest'
                AND bt.status  = 'passed'
            LEFT JOIN strategy_evaluations wf
                ON  wf.strategy_config_id = sc.id
                AND wf.stage   = 'walk_forward'
                AND wf.status  = 'passed'
            WHERE ls.id = ANY($1)
            ORDER BY ls.id, sc.score DESC NULLS LAST
            "#,
            )
            .bind(&pipeline_ids)
            .fetch_all(&state.db)
            .await
            .map_err(AppError::Database)?;

        for (live_id, source, score, bt_stats, wf_stats) in pipeline_rows {
            // Map pipeline bt_stats fields to the same shape as grid-search backtest_stats.
            // Pipeline uses "sharpe" / "total_return" etc; grid search uses "sharpe_ratio".
            // avg_win / avg_loss not available from pipeline — set to null.
            let backtest_stats = bt_stats.as_ref().map(|b| {
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

            let oos_stats = wf_stats.as_ref().map(|w| {
                json!({
                    "oos_sharpe":     w["oos_sharpe"],
                    "oos_num_trades": w["oos_num_trades"],
                    "oos_return":     w["oos_return"],
                    "sharpe_retention": w["sharpe_retention"],
                })
            });

            pipeline_stats_map.insert(
                live_id,
                json!({
                    "source":         source,
                    "pipeline_score": score,
                    "backtest_stats": backtest_stats,
                    "oos_stats":      oos_stats,
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
                // Strategies with a backtest_run_id came from the grid-search / Backtests page.
                // Everything else came through the pipeline (Ollama, evo, manual promote).
                let source = if backtest_run_id.is_some() {
                    "grid_search"
                } else {
                    "pipeline"
                };

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
                    "source": source,
                });

                if let Some(bt_id) = backtest_run_id {
                    if let Some(stats) = stats_map.get(bt_id) {
                        obj["backtest_stats"] = stats.clone();
                    }
                } else if let Some(pipeline) = pipeline_stats_map.get(id) {
                    // Refine source from the strategy_config if available (e.g. "evolution")
                    obj["source"] = pipeline["source"].clone();
                    obj["pipeline_score"] = pipeline["pipeline_score"].clone();
                    obj["backtest_stats"] = pipeline["backtest_stats"].clone();
                    obj["oos_stats"] = pipeline["oos_stats"].clone();
                }

                if let Some(live) = live_stats_map.get(id) {
                    obj["live_stats"] = live.clone();
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
        return db_err.code().is_some_and(|code| code == "23505");
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

    let config: serde_json::Map<String, Value> = rows.into_iter().collect();

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
#[derive(sqlx::FromRow)]
struct LiveTradeRow {
    id: Uuid,
    live_strategy_id: Option<Uuid>,
    oanda_trade_id: Option<String>,
    instrument: String,
    direction: String,
    units: String,
    entry_price: Option<f64>,
    exit_price: Option<f64>,
    entry_time: chrono::DateTime<chrono::Utc>,
    exit_time: Option<chrono::DateTime<chrono::Utc>>,
    pnl_percent: Option<f64>,
    entry_reason: Option<String>,
    exit_reason: Option<String>,
    status: String,
    strategy_type: Option<String>,
    parameters: Option<Value>,
    granularity: Option<String>,
}

pub async fn get_live_trades(
    State(state): State<AppState>,
    Query(params): Query<LiveTradesParams>,
) -> AppResult<Json<Value>> {
    let status = params.status.unwrap_or_else(|| "all".to_string());
    let limit = params.limit.unwrap_or(50);

    let select_cols = r#"
        SELECT lt.id, lt.live_strategy_id, lt.oanda_trade_id, lt.instrument, lt.direction, lt.units,
               lt.entry_price, lt.exit_price, lt.entry_time, lt.exit_time,
               lt.pnl_percent, lt.entry_reason, lt.exit_reason, lt.status,
               ls.strategy_type, ls.parameters, ls.granularity
        FROM live_trades lt
        LEFT JOIN live_strategies ls ON ls.id = lt.live_strategy_id
    "#;

    let rows: Vec<LiveTradeRow> = if status == "all" {
        sqlx::query_as::<_, LiveTradeRow>(&format!(
            "{} ORDER BY lt.entry_time DESC LIMIT $1",
            select_cols
        ))
        .bind(limit)
        .fetch_all(&state.db)
        .await
        .map_err(AppError::Database)?
    } else {
        sqlx::query_as::<_, LiveTradeRow>(&format!(
            "{} WHERE lt.status = $1 ORDER BY lt.entry_time DESC LIMIT $2",
            select_cols
        ))
        .bind(&status)
        .bind(limit)
        .fetch_all(&state.db)
        .await
        .map_err(AppError::Database)?
    };

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

#[derive(sqlx::FromRow)]
struct TradeDetailRow {
    // Trade
    id: Uuid,
    live_strategy_id: Option<Uuid>,
    oanda_trade_id: Option<String>,
    instrument: String,
    direction: String,
    units: String,
    entry_price: Option<f64>,
    exit_price: Option<f64>,
    entry_time: chrono::DateTime<chrono::Utc>,
    exit_time: Option<chrono::DateTime<chrono::Utc>>,
    pnl_percent: Option<f64>,
    entry_reason: Option<String>,
    exit_reason: Option<String>,
    status: String,
    // Strategy
    strategy_type: Option<String>,
    parameters: Option<Value>,
    granularity: Option<String>,
    enabled: Option<bool>,
    max_position_size: Option<String>,
    backtest_run_id: Option<Uuid>,
    // Backtest run
    bt_strategy_name: Option<String>,
    bt_total_return: Option<f64>,
    bt_win_rate: Option<f64>,
    bt_sharpe_ratio: Option<f64>,
    bt_max_drawdown: Option<f64>,
    bt_num_trades: Option<i32>,
    bt_avg_win: Option<f64>,
    bt_avg_loss: Option<f64>,
}

pub async fn get_live_trade_detail(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let row: Option<TradeDetailRow> = sqlx::query_as(
        r#"
        SELECT lt.id, lt.live_strategy_id, lt.oanda_trade_id, lt.instrument, lt.direction, lt.units,
               lt.entry_price, lt.exit_price, lt.entry_time, lt.exit_time,
               lt.pnl_percent, lt.entry_reason, lt.exit_reason, lt.status,
               ls.strategy_type, ls.parameters, ls.granularity, ls.enabled,
               ls.max_position_size, ls.backtest_run_id,
               br.strategy_name AS bt_strategy_name,
               br.total_return AS bt_total_return,
               br.win_rate AS bt_win_rate,
               br.sharpe_ratio AS bt_sharpe_ratio,
               br.max_drawdown AS bt_max_drawdown,
               br.num_trades AS bt_num_trades,
               br.avg_win AS bt_avg_win,
               br.avg_loss AS bt_avg_loss
        FROM live_trades lt
        LEFT JOIN live_strategies ls ON ls.id = lt.live_strategy_id
        LEFT JOIN backtest_runs br ON br.id = ls.backtest_run_id
        WHERE lt.id = $1
        "#,
    )
    .bind(id)
    .fetch_optional(&state.db)
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
