use rand::seq::SliceRandom;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::db::repositories::pipeline as pipeline_repo;
use crate::engine::grid::load_candles;
use crate::engine::mean_reversion::{run as run_mean_reversion, MeanReversionParams};
use crate::engine::stats::{calculate_backtest_stats, BacktestStats};
use crate::engine::strategy::{self as strategy_mod, Strategy};
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
    // Shape detection: composite-shape params have a "components" key. This lets
    // strategy_type stay logical ("trend_following", "mean_reversion") in the DB
    // even as MR migrates to the composite shape — dispatch is driven by the
    // shape of the parameters JSON, not by strategy_type.
    let is_composite = config
        .parameters
        .as_object()
        .map(|o| o.contains_key("components"))
        .unwrap_or(false);

    if is_composite {
        let strategy: Strategy =
            serde_json::from_value(config.parameters.clone()).map_err(|e| {
                AppError::BadRequest(format!("invalid composite strategy parameters: {}", e))
            })?;
        return Ok(strategy_mod::run_backtest(candles, &strategy));
    }

    match config.strategy_type.as_str() {
        "mean_reversion" => {
            let params: MeanReversionParams = serde_json::from_value(config.parameters.clone())
                .map_err(|e| {
                    AppError::BadRequest(format!("invalid mean_reversion parameters: {}", e))
                })?;
            Ok(run_mean_reversion(candles, &params))
        }
        "trend_following" => Err(AppError::BadRequest(
            "trend_following old-shape strategies are deprecated. \
             Rebuild as a composite strategy (TrendFollowing component) — \
             see [[decision-canonical-strategy-shape]]."
                .to_string(),
        )),
        other => Err(AppError::BadRequest(format!(
            "unknown strategy_type: {}",
            other
        ))),
    }
}

pub fn run_backtest_stats(
    candles: &[Candle],
    config: &StrategyConfig,
    active_start_idx: Option<usize>,
) -> AppResult<BacktestStats> {
    if candles.is_empty() {
        let empty: Vec<Trade> = Vec::new();
        return Ok(calculate_backtest_stats(&empty));
    }

    if let Some(idx) = active_start_idx {
        if idx >= candles.len() {
            return Err(AppError::BadRequest(format!(
                "active_start_idx {} out of range for {} candles",
                idx,
                candles.len()
            )));
        }
    }

    let trades = run_strategy(candles, config)?;

    match active_start_idx {
        None | Some(0) => Ok(calculate_backtest_stats(&trades)),
        Some(idx) => {
            let active_start_time = candles[idx].time;
            let filtered: Vec<Trade> = trades
                .into_iter()
                .filter(|t| t.entry_time >= active_start_time)
                .collect();
            Ok(calculate_backtest_stats(&filtered))
        }
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
    let row = pipeline_repo::find_strategy_config(pool, config_id)
        .await
        .map_err(AppError::Database)?
        .ok_or_else(|| AppError::NotFound(format!("strategy_config {}", config_id)))?;

    let granularity: Granularity = row
        .granularity
        .parse()
        .map_err(|e| AppError::BadRequest(format!("invalid granularity: {}", e)))?;

    Ok(StrategyConfig {
        id: config_id,
        instrument: row.instrument,
        granularity,
        strategy_type: row.strategy_type,
        parameters: row.parameters,
    })
}

async fn load_thresholds(
    pool: &PgPool,
    stage: &str,
    timeframe_class: &str,
    instrument_class: &str,
    strategy_type: &str,
) -> AppResult<Vec<ThresholdRow>> {
    let rows = pipeline_repo::load_validation_thresholds(
        pool,
        stage,
        timeframe_class,
        instrument_class,
        strategy_type,
    )
    .await
    .map_err(AppError::Database)?;

    Ok(rows
        .into_iter()
        .map(|row| ThresholdRow {
            metric: row.metric,
            operator: row.operator,
            value: row.value,
        })
        .collect())
}

async fn upsert_evaluation_running(pool: &PgPool, config_id: Uuid, stage: &str) -> AppResult<Uuid> {
    pipeline_repo::upsert_evaluation_running(pool, config_id, stage)
        .await
        .map_err(AppError::Database)
}

async fn finalize_evaluation(
    pool: &PgPool,
    evaluation_id: Uuid,
    status: &str,
    stats: &Value,
    failure_reason: Option<&str>,
) -> AppResult<()> {
    pipeline_repo::finalize_evaluation(pool, evaluation_id, status, stats, failure_reason)
        .await
        .map_err(AppError::Database)
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

    let bt_stats = match run_backtest_stats(&candles, config, None) {
        Ok(stats) => stats,
        Err(e) => {
            let failure = e.to_string();
            return fail_stage(pool, evaluation_id, failure).await;
        }
    };

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
