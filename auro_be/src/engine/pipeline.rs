use rand::seq::SliceRandom;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::engine::grid::load_candles;
use crate::engine::mean_reversion::{run as run_mean_reversion, MeanReversionParams};
use crate::engine::stats::{calculate_backtest_stats, BacktestStats};
use crate::engine::trend_following::{run as run_trend_following, TrendFollowingParams};
use crate::engine::types::{Candle, Granularity, Trade};
use crate::error::{AppError, AppResult};

pub struct StrategyConfig {
    pub id: Uuid,
    pub instrument: String,
    pub granularity: Granularity,
    pub strategy_type: String,
    pub parameters: Value,
}

pub struct EvaluationResult {
    pub evaluation_id: Uuid,
    pub status: String,
    pub stats: Value,
    pub failure_reason: Option<String>,
}

struct ThresholdRow {
    metric: String,
    operator: String,
    value: f64,
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

pub fn instrument_to_class(instrument: &str) -> &'static str {
    match instrument {
        "EUR_USD" | "GBP_USD" | "USD_JPY" | "USD_CHF" | "USD_CAD" | "AUD_USD" | "NZD_USD" => {
            "fx_major"
        }
        "XAU_USD" | "XAG_USD" | "XPT_USD" | "XPD_USD" | "XCU_USD" => "metal",
        "WTICO_USD" | "BCO_USD" | "NATGAS_USD" | "CORN_USD" | "WHEAT_USD" | "SOYBN_USD" => {
            "commodity"
        }
        "UK100_GBP" | "EU50_EUR" | "DE30_EUR" | "FR40_EUR" | "AU200_AUD" | "JP225_USD"
        | "US30_USD" | "SPX500_USD" | "NAS100_USD" | "HK33_HKD" | "SG30_SGD" => "index",
        _ => "fx_cross",
    }
}

fn run_strategy(candles: &[Candle], config: &StrategyConfig) -> AppResult<Vec<Trade>> {
    match config.strategy_type.as_str() {
        "mean_reversion" => {
            let params: MeanReversionParams = serde_json::from_value(config.parameters.clone())
                .map_err(|e| {
                    AppError::BadRequest(format!("invalid mean_reversion parameters: {}", e))
                })?;
            Ok(run_mean_reversion(candles, &params))
        }
        "trend_following" => {
            let params: TrendFollowingParams = serde_json::from_value(config.parameters.clone())
                .map_err(|e| {
                    AppError::BadRequest(format!("invalid trend_following parameters: {}", e))
                })?;
            Ok(run_trend_following(candles, &params))
        }
        other => Err(AppError::BadRequest(format!(
            "unknown strategy_type: {}",
            other
        ))),
    }
}

fn compute_expectancy(stats: &BacktestStats) -> f64 {
    let loss_rate = 1.0 - stats.win_rate;
    (stats.win_rate * stats.avg_win) - (loss_rate * stats.avg_loss.abs())
}

fn apply_threshold(operator: &str, actual: f64, threshold: f64) -> bool {
    match operator {
        "gte" => actual >= threshold,
        "lte" => actual <= threshold,
        "gt" => actual > threshold,
        "lt" => actual < threshold,
        _ => false,
    }
}

fn evaluate_thresholds(
    stats_json: &Value,
    thresholds: &[ThresholdRow],
    stage: &str,
    timeframe_class: &str,
) -> (String, Option<String>) {
    if thresholds.is_empty() {
        return (
            "failed".to_string(),
            Some(format!(
                "no thresholds configured for stage={} timeframe_class={}",
                stage, timeframe_class
            )),
        );
    }

    let failures: Vec<String> = thresholds
        .iter()
        .filter_map(|t| {
            let actual = match stats_json.get(&t.metric).and_then(|v| v.as_f64()) {
                Some(v) => v,
                None => return Some(format!("{}: missing from stats", t.metric)),
            };
            if !apply_threshold(&t.operator, actual, t.value) {
                Some(format!(
                    "{}: {:.4} does not {} {:.4}",
                    t.metric, actual, t.operator, t.value
                ))
            } else {
                None
            }
        })
        .collect();

    if failures.is_empty() {
        ("passed".to_string(), None)
    } else {
        ("failed".to_string(), Some(failures.join("; ")))
    }
}

// ---------------------------------------------------------------------------
// DB helpers
// ---------------------------------------------------------------------------

pub async fn load_strategy_config(pool: &PgPool, config_id: Uuid) -> AppResult<StrategyConfig> {
    let row = sqlx::query_as::<_, (String, String, String, Value)>(
        "SELECT instrument, granularity, strategy_type, parameters FROM strategy_configs WHERE id = $1",
    )
    .bind(config_id)
    .fetch_optional(pool)
    .await
    .map_err(AppError::Database)?
    .ok_or_else(|| AppError::NotFound(format!("strategy_config {}", config_id)))?;

    let (instrument, granularity_str, strategy_type, parameters) = row;
    let granularity: Granularity = granularity_str
        .parse()
        .map_err(|e| AppError::BadRequest(format!("invalid granularity: {}", e)))?;

    Ok(StrategyConfig {
        id: config_id,
        instrument,
        granularity,
        strategy_type,
        parameters,
    })
}

async fn load_thresholds(
    pool: &PgPool,
    stage: &str,
    timeframe_class: &str,
    instrument_class: &str,
    strategy_type: &str,
) -> AppResult<Vec<ThresholdRow>> {
    let to_rows = |rows: Vec<(String, String, f64)>| {
        rows.into_iter()
            .map(|(metric, operator, value)| ThresholdRow {
                metric,
                operator,
                value,
            })
            .collect::<Vec<_>>()
    };

    // Level 1: instrument_class + strategy_type specific.
    let rows = sqlx::query_as::<_, (String, String, f64)>(
        "SELECT metric, operator, value FROM validation_thresholds \
         WHERE stage = $1 AND timeframe_class = $2 AND instrument_class = $3 AND strategy_type = $4",
    )
    .bind(stage)
    .bind(timeframe_class)
    .bind(instrument_class)
    .bind(strategy_type)
    .fetch_all(pool)
    .await
    .map_err(AppError::Database)?;

    if !rows.is_empty() {
        return Ok(to_rows(rows));
    }

    // Level 2: instrument_class + strategy_type='all' (strategy-agnostic instrument thresholds).
    let rows = sqlx::query_as::<_, (String, String, f64)>(
        "SELECT metric, operator, value FROM validation_thresholds \
         WHERE stage = $1 AND timeframe_class = $2 AND instrument_class = $3 AND strategy_type = 'all'",
    )
    .bind(stage)
    .bind(timeframe_class)
    .bind(instrument_class)
    .fetch_all(pool)
    .await
    .map_err(AppError::Database)?;

    if !rows.is_empty() {
        return Ok(to_rows(rows));
    }

    // Level 3: catch-all (instrument_class='all', strategy_type='all').
    let rows = sqlx::query_as::<_, (String, String, f64)>(
        "SELECT metric, operator, value FROM validation_thresholds \
         WHERE stage = $1 AND timeframe_class = $2 AND instrument_class = 'all' AND strategy_type = 'all'",
    )
    .bind(stage)
    .bind(timeframe_class)
    .fetch_all(pool)
    .await
    .map_err(AppError::Database)?;

    Ok(to_rows(rows))
}

async fn upsert_evaluation_running(pool: &PgPool, config_id: Uuid, stage: &str) -> AppResult<Uuid> {
    let row = sqlx::query_as::<_, (Uuid,)>(
        r#"
        INSERT INTO strategy_evaluations (id, strategy_config_id, stage, status, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, 'running', NOW(), NOW())
        ON CONFLICT (strategy_config_id, stage)
        DO UPDATE SET status = 'running', stats = NULL, failure_reason = NULL, evaluated_at = NULL, updated_at = NOW()
        RETURNING id
        "#,
    )
    .bind(config_id)
    .bind(stage)
    .fetch_one(pool)
    .await
    .map_err(AppError::Database)?;

    Ok(row.0)
}

async fn finalize_evaluation(
    pool: &PgPool,
    evaluation_id: Uuid,
    status: &str,
    stats: &Value,
    failure_reason: Option<&str>,
) -> AppResult<()> {
    sqlx::query(
        r#"
        UPDATE strategy_evaluations
        SET status = $1, stats = $2, failure_reason = $3, evaluated_at = NOW(), updated_at = NOW()
        WHERE id = $4
        "#,
    )
    .bind(status)
    .bind(stats)
    .bind(failure_reason)
    .bind(evaluation_id)
    .execute(pool)
    .await
    .map_err(AppError::Database)?;

    Ok(())
}

async fn fail_stage(
    pool: &PgPool,
    evaluation_id: Uuid,
    failure: String,
) -> AppResult<EvaluationResult> {
    let stats = serde_json::json!({});
    finalize_evaluation(pool, evaluation_id, "failed", &stats, Some(&failure)).await?;
    Ok(EvaluationResult {
        evaluation_id,
        status: "failed".to_string(),
        stats,
        failure_reason: Some(failure),
    })
}

// ---------------------------------------------------------------------------
// Backtest stage
// ---------------------------------------------------------------------------

fn backtest_stats_to_json(stats: &BacktestStats) -> Value {
    let expectancy = compute_expectancy(stats);
    serde_json::json!({
        "sharpe":       stats.sharpe_ratio,
        "max_drawdown": stats.max_drawdown.abs(),
        "num_trades":   stats.num_trades,
        "win_rate":     stats.win_rate,
        "total_return": stats.total_return,
        "expectancy":   expectancy,
    })
}

pub async fn run_backtest(pool: &PgPool, config: &StrategyConfig) -> AppResult<EvaluationResult> {
    let evaluation_id = upsert_evaluation_running(pool, config.id, "backtest").await?;

    let candles = load_candles(pool, &config.instrument, config.granularity.as_str())
        .await
        .map_err(AppError::Database)?;

    if candles.is_empty() {
        let failure = format!(
            "no candle data for {} {}",
            config.instrument, config.granularity
        );
        return fail_stage(pool, evaluation_id, failure).await;
    }

    let trades = match run_strategy(&candles, config) {
        Ok(t) => t,
        Err(e) => {
            let failure = e.to_string();
            return fail_stage(pool, evaluation_id, failure).await;
        }
    };

    let bt_stats = calculate_backtest_stats(&trades);
    let stats_json = backtest_stats_to_json(&bt_stats);
    let timeframe_class = config.granularity.timeframe_class();
    let instrument_class = instrument_to_class(&config.instrument);
    let thresholds = load_thresholds(
        pool,
        "backtest",
        timeframe_class,
        instrument_class,
        &config.strategy_type,
    )
    .await?;
    let (status, failure_reason) =
        evaluate_thresholds(&stats_json, &thresholds, "backtest", timeframe_class);

    finalize_evaluation(
        pool,
        evaluation_id,
        &status,
        &stats_json,
        failure_reason.as_deref(),
    )
    .await?;

    tracing::info!(
        config_id = %config.id,
        instrument = %config.instrument,
        granularity = %config.granularity,
        strategy_type = %config.strategy_type,
        stage = "backtest",
        status = %status,
        num_trades = bt_stats.num_trades,
        sharpe = bt_stats.sharpe_ratio,
        "pipeline stage complete"
    );

    Ok(EvaluationResult {
        evaluation_id,
        status,
        stats: stats_json,
        failure_reason,
    })
}

// ---------------------------------------------------------------------------
// Walk-forward stage
// ---------------------------------------------------------------------------

fn walk_forward_stats_to_json(is_stats: &BacktestStats, oos_stats: &BacktestStats) -> Value {
    let sharpe_retention = if is_stats.sharpe_ratio.abs() < f64::EPSILON {
        0.0
    } else {
        oos_stats.sharpe_ratio / is_stats.sharpe_ratio
    };

    serde_json::json!({
        // Evaluated against thresholds
        "oos_sharpe":       oos_stats.sharpe_ratio,
        "oos_return":       oos_stats.total_return,
        "oos_num_trades":   oos_stats.num_trades,
        "sharpe_retention": sharpe_retention,
        // Context only — not threshold-evaluated
        "is_sharpe":        is_stats.sharpe_ratio,
        "is_num_trades":    is_stats.num_trades,
        "is_return":        is_stats.total_return,
    })
}

pub async fn run_walk_forward(
    pool: &PgPool,
    config: &StrategyConfig,
) -> AppResult<EvaluationResult> {
    let evaluation_id = upsert_evaluation_running(pool, config.id, "walk_forward").await?;

    let candles = load_candles(pool, &config.instrument, config.granularity.as_str())
        .await
        .map_err(AppError::Database)?;

    // Need enough candles for a meaningful OOS window
    if candles.len() < 50 {
        let failure = format!(
            "insufficient candles for walk_forward: {} (need >= 50)",
            candles.len()
        );
        return fail_stage(pool, evaluation_id, failure).await;
    }

    // 70/30 split: IS is the first 70%, OOS is the last 30%
    let split = candles.len() * 7 / 10;
    let is_candles = &candles[..split];
    let oos_candles = &candles[split..];

    let is_trades = match run_strategy(is_candles, config) {
        Ok(t) => t,
        Err(e) => {
            let failure = format!("IS run failed: {}", e);
            return fail_stage(pool, evaluation_id, failure).await;
        }
    };

    let oos_trades = match run_strategy(oos_candles, config) {
        Ok(t) => t,
        Err(e) => {
            let failure = format!("OOS run failed: {}", e);
            return fail_stage(pool, evaluation_id, failure).await;
        }
    };

    let is_stats = calculate_backtest_stats(&is_trades);
    let oos_stats = calculate_backtest_stats(&oos_trades);
    let stats_json = walk_forward_stats_to_json(&is_stats, &oos_stats);
    let timeframe_class = config.granularity.timeframe_class();
    let instrument_class = instrument_to_class(&config.instrument);
    let thresholds = load_thresholds(
        pool,
        "walk_forward",
        timeframe_class,
        instrument_class,
        &config.strategy_type,
    )
    .await?;
    let (status, failure_reason) =
        evaluate_thresholds(&stats_json, &thresholds, "walk_forward", timeframe_class);

    finalize_evaluation(
        pool,
        evaluation_id,
        &status,
        &stats_json,
        failure_reason.as_deref(),
    )
    .await?;

    tracing::info!(
        config_id = %config.id,
        instrument = %config.instrument,
        granularity = %config.granularity,
        strategy_type = %config.strategy_type,
        stage = "walk_forward",
        status = %status,
        is_candles = is_candles.len(),
        oos_candles = oos_candles.len(),
        is_sharpe = is_stats.sharpe_ratio,
        oos_sharpe = oos_stats.sharpe_ratio,
        "pipeline stage complete"
    );

    Ok(EvaluationResult {
        evaluation_id,
        status,
        stats: stats_json,
        failure_reason,
    })
}

// ---------------------------------------------------------------------------
// Monte Carlo stage
// ---------------------------------------------------------------------------

const MONTE_CARLO_SIMS: usize = 10_000;

struct SimStats {
    total_return: f64,
    max_drawdown: f64, // positive fraction
    sharpe: f64,
}

fn sim_stats_from_pnls(pnls: &[f64]) -> SimStats {
    let n = pnls.len() as f64;
    let total_return: f64 = pnls.iter().sum();

    let mean = total_return / n;
    let variance = pnls.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / n;
    let sharpe = if variance < f64::EPSILON {
        0.0
    } else {
        mean / variance.sqrt()
    };

    let mut cumulative = 0.0_f64;
    let mut peak = 0.0_f64;
    let mut max_drawdown = 0.0_f64;
    for &pnl in pnls {
        cumulative += pnl;
        if cumulative > peak {
            peak = cumulative;
        }
        let dd = if peak > 0.0 {
            (peak - cumulative) / (1.0 + peak)
        } else {
            0.0
        };
        if dd > max_drawdown {
            max_drawdown = dd;
        }
    }

    SimStats {
        total_return,
        max_drawdown,
        sharpe,
    }
}

fn run_monte_carlo_sims(trades: &[Trade]) -> Value {
    let mut pnls: Vec<f64> = trades.iter().map(|t| t.pnl_percent).collect();
    let mut rng = rand::rng();

    let mut profitable_count: usize = 0;
    let mut all_sharpes: Vec<f64> = Vec::with_capacity(MONTE_CARLO_SIMS);
    let mut all_drawdowns: Vec<f64> = Vec::with_capacity(MONTE_CARLO_SIMS);

    for _ in 0..MONTE_CARLO_SIMS {
        pnls.shuffle(&mut rng);
        let sim = sim_stats_from_pnls(&pnls);

        if sim.total_return > 0.0 {
            profitable_count += 1;
        }
        all_sharpes.push(sim.sharpe);
        all_drawdowns.push(sim.max_drawdown);
    }

    let profitable_pct = profitable_count as f64 / MONTE_CARLO_SIMS as f64;

    all_sharpes.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let median_sharpe =
        (all_sharpes[MONTE_CARLO_SIMS / 2 - 1] + all_sharpes[MONTE_CARLO_SIMS / 2]) / 2.0;

    all_drawdowns.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let p95_idx = MONTE_CARLO_SIMS * 95 / 100; // index 9500 → 95th percentile
    let p95_drawdown = all_drawdowns[p95_idx];

    serde_json::json!({
        // Evaluated against thresholds
        "profitable_pct": profitable_pct,
        "median_sharpe":  median_sharpe,
        "p95_drawdown":   p95_drawdown,
        // Context only
        "num_trades":     trades.len(),
        "num_sims":       MONTE_CARLO_SIMS,
    })
}

pub async fn run_monte_carlo(
    pool: &PgPool,
    config: &StrategyConfig,
) -> AppResult<EvaluationResult> {
    let evaluation_id = upsert_evaluation_running(pool, config.id, "monte_carlo").await?;

    let candles = load_candles(pool, &config.instrument, config.granularity.as_str())
        .await
        .map_err(AppError::Database)?;

    let trades = match run_strategy(&candles, config) {
        Ok(t) => t,
        Err(e) => {
            let failure = e.to_string();
            return fail_stage(pool, evaluation_id, failure).await;
        }
    };

    if trades.len() < 2 {
        let failure = format!(
            "too few trades for Monte Carlo: {} (need >= 2)",
            trades.len()
        );
        return fail_stage(pool, evaluation_id, failure).await;
    }

    let stats_json = run_monte_carlo_sims(&trades);
    let timeframe_class = config.granularity.timeframe_class();
    let instrument_class = instrument_to_class(&config.instrument);
    let thresholds = load_thresholds(
        pool,
        "monte_carlo",
        timeframe_class,
        instrument_class,
        &config.strategy_type,
    )
    .await?;
    let (status, failure_reason) =
        evaluate_thresholds(&stats_json, &thresholds, "monte_carlo", timeframe_class);

    finalize_evaluation(
        pool,
        evaluation_id,
        &status,
        &stats_json,
        failure_reason.as_deref(),
    )
    .await?;

    tracing::info!(
        config_id = %config.id,
        instrument = %config.instrument,
        granularity = %config.granularity,
        strategy_type = %config.strategy_type,
        stage = "monte_carlo",
        status = %status,
        num_trades = trades.len(),
        sims = MONTE_CARLO_SIMS,
        "pipeline stage complete"
    );

    Ok(EvaluationResult {
        evaluation_id,
        status,
        stats: stats_json,
        failure_reason,
    })
}
