use chrono::{DateTime, Utc};
use rand::RngExt;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::db::repositories::candles::load_candles;
use crate::db::repositories::financing as financing_repo;
use crate::db::repositories::live_strategies as live_strategies_repo;
use crate::db::repositories::pipeline as pipeline_repo;
use crate::engine::financing::{apply_financing, FinancingModel};
use crate::engine::stats::{calculate_backtest_stats, BacktestStats};
use crate::engine::strategy::{self as strategy_mod, Strategy};
use crate::engine::types::{Candle, Granularity, Trade};
use crate::error::{AppError, AppResult};

#[derive(Clone)]
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

pub(crate) struct ThresholdRow {
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
        "WTICO_USD" | "BCO_USD" | "NATGAS_USD" | "CORN_USD" | "WHEAT_USD" | "SOYBN_USD"
        | "SUGAR_USD" => "commodity",
        "UK100_GBP" | "EU50_EUR" | "DE30_EUR" | "FR40_EUR" | "NL25_EUR" | "CH20_CHF"
        | "AU200_AUD" | "JP225_USD" | "HK33_HKD" | "CN50_USD" | "SG30_SGD" | "US30_USD"
        | "SPX500_USD" | "NAS100_USD" | "US2000_USD" => "index",
        "USB02Y_USD" | "USB10Y_USD" | "USB30Y_USD" | "DE10YB_EUR" | "UK10YB_GBP" => "bond",
        _ => "fx_cross",
    }
}

pub(crate) fn run_strategy(
    candles: &[Candle],
    config: &StrategyConfig,
    financing: &FinancingModel,
) -> AppResult<Vec<Trade>> {
    // All strategies use the composite shape. Pre-composite flat-shape strategies
    // were purged with the DB wipe; see [[decision-canonical-strategy-shape]].
    let strategy: Strategy = serde_json::from_value(config.parameters.clone()).map_err(|e| {
        AppError::BadRequest(format!(
            "invalid composite strategy parameters for strategy_type={}: {}",
            config.strategy_type, e
        ))
    })?;

    // A warmup the live buffer can't hold means the strategy is dead live —
    // fail loudly here instead of silently producing zero trades.
    let warmup = strategy.warmup();
    let capacity = strategy.granularity.buffer_capacity();
    if warmup + 1 > capacity {
        return Err(AppError::BadRequest(format!(
            "warmup {} exceeds live buffer capacity {} for {} — strategy could never trade live",
            warmup, capacity, strategy.granularity
        )));
    }

    let mut trades = strategy_mod::run_backtest(candles, &strategy);
    apply_financing(&mut trades, &config.instrument, financing);
    Ok(trades)
}

pub fn run_backtest_stats(
    candles: &[Candle],
    config: &StrategyConfig,
    active_start_idx: Option<usize>,
    financing: &FinancingModel,
) -> AppResult<BacktestStats> {
    if candles.is_empty() {
        let empty: Vec<Trade> = Vec::new();
        let (from, to) = span(candles);
        return Ok(calculate_backtest_stats(&empty, from, to));
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

    let trades = run_strategy(candles, config, financing)?;

    match active_start_idx {
        None | Some(0) => {
            let (from, to) = span(candles);
            Ok(calculate_backtest_stats(&trades, from, to))
        }
        Some(idx) => {
            let active_start_time = candles[idx].time;
            let filtered: Vec<Trade> = trades
                .into_iter()
                .filter(|t| t.entry_time >= active_start_time)
                .collect();
            let (from, to) = span(&candles[idx..]);
            Ok(calculate_backtest_stats(&filtered, from, to))
        }
    }
}

/// Overnight financing model for a stage's backtests (one DB read per stage).
pub(crate) async fn load_financing(pool: &PgPool) -> AppResult<FinancingModel> {
    financing_repo::load_model(pool)
        .await
        .map_err(|e| AppError::Internal(format!("load financing model: {e}")))
}

/// How many standard errors the average trade sits above zero: the
/// per-trade Sharpe (mean / spread of trade returns) times √trades. Around
/// 2 or more means a result this good would rarely come from luck alone.
/// The stretch `candles` cover, first bar to last, for the annual Sharpe.
/// An empty slice is an empty stretch.
pub(crate) fn span(candles: &[Candle]) -> (DateTime<Utc>, DateTime<Utc>) {
    match (candles.first(), candles.last()) {
        (Some(first), Some(last)) => (first.time, last.time),
        _ => (Utc::now(), Utc::now()),
    }
}

pub(crate) fn t_stat(stats: &BacktestStats) -> f64 {
    stats.sharpe_ratio * (stats.num_trades as f64).sqrt()
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

fn operator_failure_text(operator: &str) -> &'static str {
    match operator {
        "gte" => "is below minimum",
        "gt" => "must be greater than",
        "lte" => "is above maximum",
        "lt" => "must be less than",
        _ => "does not satisfy",
    }
}

/// Judge stage stats against the thresholds, and record every check in
/// `stats_json["checks"]` (`metric`, `operator`, `required`, `actual`,
/// `passed`) so a page can show each rule next to its result.
pub(crate) fn evaluate_thresholds(
    stats_json: &mut Value,
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

    let checks: Vec<(&ThresholdRow, Option<f64>, bool)> = thresholds
        .iter()
        .map(|t| {
            let actual = stats_json.get(&t.metric).and_then(|v| v.as_f64());
            let passed = actual.is_some_and(|a| apply_threshold(&t.operator, a, t.value));
            (t, actual, passed)
        })
        .collect();

    let failures: Vec<String> = checks
        .iter()
        .filter(|(_, _, passed)| !passed)
        .map(|(t, actual, _)| match actual {
            None => format!("{}: missing from stats", t.metric),
            Some(a) => format!(
                "{}: {:.4} {} {:.4}",
                t.metric,
                a,
                operator_failure_text(&t.operator),
                t.value
            ),
        })
        .collect();

    stats_json["checks"] = Value::Array(
        checks
            .iter()
            .map(|(t, actual, passed)| {
                serde_json::json!({
                    "metric": t.metric,
                    "operator": t.operator,
                    "required": t.value,
                    "actual": actual,
                    "passed": passed,
                })
            })
            .collect(),
    );

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

pub(crate) async fn load_thresholds(
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
// Sealed holdout
// ---------------------------------------------------------------------------

/// Start of the sealed holdout window: `trading_config.pipeline_holdout_start`,
/// an ISO date. The exploration stages (backtest, walk-forward, Monte Carlo)
/// never see bars from it onward; the holdout stage alone does, once per
/// config. A missing or malformed value is an error rather than "no holdout":
/// the pipeline must not run unsealed by accident.
pub async fn load_holdout_start(pool: &PgPool) -> AppResult<chrono::DateTime<chrono::Utc>> {
    let rows = live_strategies_repo::list_trading_config(pool)
        .await
        .map_err(AppError::Database)?;
    let raw = rows
        .iter()
        .find(|r| r.key == "pipeline_holdout_start")
        .and_then(|r| r.value.as_str().map(str::to_string))
        .ok_or_else(|| {
            AppError::Internal(
                "trading_config.pipeline_holdout_start is not set; refusing to run the pipeline unsealed"
                    .into(),
            )
        })?;
    let date = chrono::NaiveDate::parse_from_str(&raw, "%Y-%m-%d").map_err(|e| {
        AppError::Internal(format!(
            "pipeline_holdout_start {raw:?} is not an ISO date: {e}"
        ))
    })?;
    Ok(chrono::DateTime::from_naive_utc_and_offset(
        date.and_hms_opt(0, 0, 0).expect("midnight exists"),
        chrono::Utc,
    ))
}

/// The bars an exploration stage may see: everything before the holdout.
pub(crate) async fn load_exploration_candles(
    pool: &PgPool,
    config: &StrategyConfig,
) -> AppResult<Vec<Candle>> {
    let holdout_start = load_holdout_start(pool).await?;
    let candles = load_candles(pool, &config.instrument, config.granularity)
        .await
        .map_err(AppError::Database)?;
    Ok(candles
        .into_iter()
        .filter(|c| c.time < holdout_start)
        .collect())
}

/// The one look at the sealed window: the strategy runs over full history
/// (so indicators warm up on exploration bars) and only trades entered on or
/// after the holdout start count. `holdout_looks` in the stats is how many
/// sibling candidates (same instrument and strategy type) have been judged
/// on this window, this one included — the more looks, the less a pass means.
pub async fn run_holdout(pool: &PgPool, config: &StrategyConfig) -> AppResult<EvaluationResult> {
    let evaluation_id = upsert_evaluation_running(pool, config.id, "holdout").await?;

    let holdout_start = load_holdout_start(pool).await?;
    let candles = load_candles(pool, &config.instrument, config.granularity)
        .await
        .map_err(AppError::Database)?;
    let Some(active_start_idx) = candles.iter().position(|c| c.time >= holdout_start) else {
        let failure = format!(
            "no candles in the holdout window for {} {} (from {})",
            config.instrument,
            config.granularity,
            holdout_start.format("%Y-%m-%d")
        );
        return fail_stage(pool, evaluation_id, failure).await;
    };

    let financing = load_financing(pool).await?;
    let stats = match run_backtest_stats(&candles, config, Some(active_start_idx), &financing) {
        Ok(stats) => stats,
        Err(e) => {
            let failure = e.to_string();
            return fail_stage(pool, evaluation_id, failure).await;
        }
    };
    let looks = pipeline_repo::count_holdout_looks(pool, &config.instrument, &config.strategy_type)
        .await
        .map_err(AppError::Database)?;

    let mut stats_json = backtest_stats_to_json(&stats);
    stats_json["holdout_start"] = serde_json::json!(holdout_start.format("%Y-%m-%d").to_string());
    stats_json["holdout_looks"] = serde_json::json!(looks);

    let timeframe_class = config.granularity.timeframe_class();
    let instrument_class = instrument_to_class(&config.instrument);
    let thresholds = load_thresholds(
        pool,
        "holdout",
        timeframe_class,
        instrument_class,
        &config.strategy_type,
    )
    .await?;
    let (status, failure_reason) =
        evaluate_thresholds(&mut stats_json, &thresholds, "holdout", timeframe_class);

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
        status = %status,
        holdout_looks = looks,
        "[Pipeline] holdout stage complete"
    );

    Ok(EvaluationResult {
        evaluation_id,
        status,
        stats: stats_json,
        failure_reason,
    })
}

// ---------------------------------------------------------------------------
// Backtest stage
// ---------------------------------------------------------------------------

pub(crate) fn backtest_stats_to_json(stats: &BacktestStats) -> Value {
    let expectancy = compute_expectancy(stats);
    serde_json::json!({
        "sharpe":        stats.sharpe_ratio,
        "annual_sharpe": stats.annual_sharpe,
        "t_stat":        t_stat(stats),
        "max_drawdown": stats.max_drawdown.abs(),
        "num_trades":   stats.num_trades,
        "win_rate":     stats.win_rate,
        "total_return": stats.total_return,
        "expectancy":   expectancy,
    })
}

pub async fn run_backtest(pool: &PgPool, config: &StrategyConfig) -> AppResult<EvaluationResult> {
    let evaluation_id = upsert_evaluation_running(pool, config.id, "backtest").await?;

    let candles = load_exploration_candles(pool, config).await?;

    if candles.is_empty() {
        let failure = format!(
            "no candle data for {} {}",
            config.instrument, config.granularity
        );
        return fail_stage(pool, evaluation_id, failure).await;
    }

    let financing = load_financing(pool).await?;
    let bt_stats = match run_backtest_stats(&candles, config, None, &financing) {
        Ok(stats) => stats,
        Err(e) => {
            let failure = e.to_string();
            return fail_stage(pool, evaluation_id, failure).await;
        }
    };

    let mut stats_json = backtest_stats_to_json(&bt_stats);
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
        evaluate_thresholds(&mut stats_json, &thresholds, "backtest", timeframe_class);

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
        "oos_annual_sharpe": oos_stats.annual_sharpe,
        "oos_t_stat":       t_stat(oos_stats),
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

    let candles = load_exploration_candles(pool, config).await?;

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

    let financing = load_financing(pool).await?;
    let is_trades = match run_strategy(is_candles, config, &financing) {
        Ok(t) => t,
        Err(e) => {
            let failure = format!("IS run failed: {}", e);
            return fail_stage(pool, evaluation_id, failure).await;
        }
    };

    let oos_trades = match run_strategy(oos_candles, config, &financing) {
        Ok(t) => t,
        Err(e) => {
            let failure = format!("OOS run failed: {}", e);
            return fail_stage(pool, evaluation_id, failure).await;
        }
    };

    let (is_from, is_to) = span(is_candles);
    let (oos_from, oos_to) = span(oos_candles);
    let is_stats = calculate_backtest_stats(&is_trades, is_from, is_to);
    let oos_stats = calculate_backtest_stats(&oos_trades, oos_from, oos_to);
    let mut stats_json = walk_forward_stats_to_json(&is_stats, &oos_stats);
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
    let (status, failure_reason) = evaluate_thresholds(
        &mut stats_json,
        &thresholds,
        "walk_forward",
        timeframe_class,
    );

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
    let pool: Vec<f64> = trades.iter().map(|t| t.pnl_percent).collect();
    let n = pool.len();
    let mut sample = Vec::with_capacity(n);
    let mut rng = rand::rng();

    let mut profitable_count: usize = 0;
    let mut all_sharpes: Vec<f64> = Vec::with_capacity(MONTE_CARLO_SIMS);
    let mut all_drawdowns: Vec<f64> = Vec::with_capacity(MONTE_CARLO_SIMS);

    for _ in 0..MONTE_CARLO_SIMS {
        sample.clear();

        for _ in 0..n {
            let idx = rng.random_range(0..n);
            sample.push(pool[idx]);
        }

        let sim = sim_stats_from_pnls(&sample);

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

    let candles = load_exploration_candles(pool, config).await?;

    let financing = load_financing(pool).await?;
    let trades = match run_strategy(&candles, config, &financing) {
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

    let mut stats_json = run_monte_carlo_sims(&trades);
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
        evaluate_thresholds(&mut stats_json, &thresholds, "monte_carlo", timeframe_class);

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

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    use crate::engine::types::{Direction, EntryReason, ExitReason, Trade};

    fn trade_with_pnl(pnl: f64) -> Trade {
        Trade {
            direction: Direction::Long,
            entry_price: 1.0,
            exit_price: 1.0,
            entry_time: Utc::now(),
            exit_time: Utc::now(),
            pnl_percent: pnl,
            entry_reason: EntryReason::CrossAbove {
                fast_ma: 0.0,
                slow_ma: 0.0,
            },
            exit_reason: ExitReason::TrendReversal,
            stop_price: 0.0,
        }
    }

    fn threshold(metric: &str, operator: &str, value: f64) -> ThresholdRow {
        ThresholdRow {
            metric: metric.to_string(),
            operator: operator.to_string(),
            value,
        }
    }

    #[test]
    fn every_check_is_recorded_with_what_it_needed_and_got() {
        let mut stats = serde_json::json!({"num_trades": 40.0, "t_stat": 1.5});
        let (status, failure) = evaluate_thresholds(
            &mut stats,
            &[
                threshold("num_trades", "gte", 30.0),
                threshold("t_stat", "gte", 2.0),
            ],
            "backtest",
            "H4",
        );

        assert_eq!(status, "failed");
        assert_eq!(
            failure.as_deref(),
            Some("t_stat: 1.5000 is below minimum 2.0000")
        );
        assert_eq!(
            stats["checks"],
            serde_json::json!([
                {"metric": "num_trades", "operator": "gte", "required": 30.0, "actual": 40.0, "passed": true},
                {"metric": "t_stat", "operator": "gte", "required": 2.0, "actual": 1.5, "passed": false}
            ])
        );
    }

    #[test]
    fn t_stat_is_per_trade_sharpe_times_root_trades() {
        let trades: Vec<Trade> = [0.02, -0.01, 0.03, 0.01]
            .iter()
            .map(|&p| trade_with_pnl(p))
            .collect();
        let stats = calculate_backtest_stats(&trades, Utc::now(), Utc::now());

        assert!((t_stat(&stats) - stats.sharpe_ratio * 2.0).abs() < 1e-12);
        assert!(backtest_stats_to_json(&stats)["t_stat"].as_f64().is_some());
    }

    #[test]
    fn monte_carlo_profitable_pct_varies_with_pool() {
        let trades = vec![
            trade_with_pnl(1.0),
            trade_with_pnl(1.0),
            trade_with_pnl(1.0),
            trade_with_pnl(-2.0),
        ];

        let stats = run_monte_carlo_sims(&trades);
        let profitable_pct = stats
            .get("profitable_pct")
            .and_then(|v| v.as_f64())
            .expect("profitable_pct should be present");

        assert!(profitable_pct > 0.0, "expected profitable_pct > 0.0");
        assert!(profitable_pct < 1.0, "expected profitable_pct < 1.0");
    }

    #[test]
    fn monte_carlo_results_vary_between_runs() {
        // Two independent MC runs on the same pool should produce different
        // median_sharpe values. Under the prior permutation implementation,
        // median_sharpe was permutation-invariant (computed from the same
        // multiset) and identical across every run regardless of RNG state —
        // this assertion would have failed. Under bootstrap-with-replacement,
        // each run samples a different multiset and the medians diverge.
        //
        // Pool needs enough distinct magnitudes that the per-sim sharpe
        // distribution is approximately continuous; a tiny pool with few
        // distinct values gives a discrete sharpe distribution whose median
        // can land on the same atom in both runs.
        let trades = vec![
            trade_with_pnl(3.0),
            trade_with_pnl(2.0),
            trade_with_pnl(1.5),
            trade_with_pnl(1.0),
            trade_with_pnl(0.5),
            trade_with_pnl(-0.5),
            trade_with_pnl(-1.0),
            trade_with_pnl(-1.5),
            trade_with_pnl(-2.0),
            trade_with_pnl(-2.5),
        ];

        let run_a = run_monte_carlo_sims(&trades);
        let run_b = run_monte_carlo_sims(&trades);

        let median_a = run_a
            .get("median_sharpe")
            .and_then(|v| v.as_f64())
            .expect("median_sharpe should be present");
        let median_b = run_b
            .get("median_sharpe")
            .and_then(|v| v.as_f64())
            .expect("median_sharpe should be present");

        assert!(
            (median_a - median_b).abs() > 1e-9,
            "expected median_sharpe to differ between MC runs (a={}, b={})",
            median_a,
            median_b
        );
    }

    #[test]
    fn monte_carlo_all_winners_gives_profitable_pct_1() {
        let trades = vec![
            trade_with_pnl(0.5),
            trade_with_pnl(1.0),
            trade_with_pnl(2.0),
            trade_with_pnl(3.0),
        ];

        let stats = run_monte_carlo_sims(&trades);
        let profitable_pct = stats
            .get("profitable_pct")
            .and_then(|v| v.as_f64())
            .expect("profitable_pct should be present");

        assert!((profitable_pct - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn monte_carlo_all_losers_gives_profitable_pct_0() {
        let trades = vec![
            trade_with_pnl(-0.5),
            trade_with_pnl(-1.0),
            trade_with_pnl(-2.0),
            trade_with_pnl(-3.0),
        ];

        let stats = run_monte_carlo_sims(&trades);
        let profitable_pct = stats
            .get("profitable_pct")
            .and_then(|v| v.as_f64())
            .expect("profitable_pct should be present");

        assert!((profitable_pct - 0.0).abs() < f64::EPSILON);
    }
}
