use chrono::{DateTime, Duration, Utc};
use sqlx::PgPool;
use std::time::Instant;
use uuid::Uuid;

use crate::engine::mean_reversion::{run as run_mean_reversion, MeanReversionParams};
use crate::engine::stats::{self, BacktestStats};
use crate::engine::trend_following::{run as run_trend_following, TrendFollowingParams};
use crate::engine::types::{Candle, EntryReason, ExitReason, Trade};

#[derive(Debug, Clone)]
pub struct GridSearchConfig {
    pub instrument: String,
    pub granularity: String,
    pub ma_periods: Vec<usize>,
    pub entry_thresholds: Vec<f64>,
    pub exit_thresholds: Vec<f64>,
    pub stop_losses: Vec<f64>,
}

impl GridSearchConfig {
    pub fn total_combinations(&self) -> usize {
        self.ma_periods.len()
            * self.entry_thresholds.len()
            * self.exit_thresholds.len()
            * self.stop_losses.len()
    }
}

#[derive(Debug)]
pub struct GridSearchResult {
    pub strategy_type: String,
    pub strategy_name: String,
    pub params_json: serde_json::Value,
    pub stats: BacktestStats,
    pub trades: Vec<Trade>,
    pub status: String,
    pub reason_flagged: Option<String>,
    pub duration_ms: u128,
}

#[derive(Debug, Clone)]
pub struct TrendGridConfig {
    pub instrument: String,
    pub granularity: String,
    pub fast_periods: Vec<usize>,
    pub slow_periods: Vec<usize>,
    pub stop_losses: Vec<f64>,
    pub take_profits: Vec<Option<f64>>,
}

impl TrendGridConfig {
    pub fn total_combinations(&self) -> usize {
        self.fast_periods.len()
            * self.slow_periods.len()
            * self.stop_losses.len()
            * self.take_profits.len()
    }
}

/// Flags a result based on the backtest statistics.
///
/// Parameters:
/// - `stats`: A reference to the [`BacktestStats`] struct.
///
/// Returns a tuple of the status ("failed" or "verified") and an optional reason.
fn flag_result(
    stats: &BacktestStats,
    strategy_type: &str,
    last_trade_time: Option<DateTime<Utc>>,
) -> (String, Option<String>) {
    // Auto-fail — universal
    if stats.max_drawdown < -0.30 {
        return ("failed".into(), Some("Max drawdown > 30%".into()));
    }
    if stats.num_trades < 10 {
        return ("failed".into(), Some("Insufficient trades (< 10)".into()));
    }

    // Strategy-specific thresholds
    let (min_win_rate, min_sharpe) = match strategy_type {
        "trend_following" => (0.25, 0.10), // trend following wins less often but bigger
        _ => (0.40, 0.30),                 // mean reversion expects higher win rate
    };

    if stats.num_trades > 0 && stats.win_rate < min_win_rate {
        return (
            "failed".into(),
            Some(format!("Win rate < {}%", (min_win_rate * 100.0) as i32)),
        );
    }
    if stats.num_trades > 0 && stats.sharpe_ratio < min_sharpe {
        return (
            "failed".into(),
            Some(format!("Sharpe ratio < {}", min_sharpe)),
        );
    }

    // Auto-verify — suspicious
    if stats.total_return > 1.0 {
        return (
            "verify".into(),
            Some("Total return > 100% — possible overfitting".into()),
        );
    }
    if stats.win_rate > 0.90 {
        return ("verify".into(), Some("Win rate > 90% — too perfect".into()));
    }
    if stats.num_trades > 1000 {
        return ("verify".into(), Some("Overtrading (> 1000 trades)".into()));
    }

    if let Some(last_time) = last_trade_time {
        let one_year_ago = Utc::now() - Duration::days(365);
        if last_time < one_year_ago {
            return (
                "verify".into(),
                Some("Last trade > 1 year ago - may not work on current data".into()),
            );
        }
    }

    ("valid".into(), None)
}

/// Loads candles from the database for a given instrument and granularity.
///
/// Parameters:
/// - `pool`: A reference to the database connection pool.
/// - `instrument`: The instrument symbol (e.g., "BTC/USD").
/// - `granularity`: The granularity of the candles (e.g., "1h", "1d").
///
/// Returns a vector of [`Candle`] structs.
pub async fn load_candles(
    pool: &PgPool,
    instrument: &str,
    granularity: &str,
) -> Result<Vec<Candle>, sqlx::Error> {
    let rows = sqlx::query_as::<_, (chrono::DateTime<Utc>, f64, f64, f64, f64, i32)>(
        r#"
        SELECT timestamp, open, high, low, close, volume
        FROM candles
        WHERE instrument = $1 AND granularity = $2 AND complete = true
        ORDER BY timestamp ASC
        "#,
    )
    .bind(instrument)
    .bind(granularity)
    .fetch_all(pool)
    .await?;

    let candles = rows
        .into_iter()
        .map(|(time, open, high, low, close, volume)| Candle {
            time,
            open,
            high,
            low,
            close,
            volume,
        })
        .collect();

    Ok(candles)
}

/// Runs a grid search over the given candles using the provided configuration.
///
/// Parameters:
/// - `candles`: A slice of [`Candle`] structs.
/// - `config`: A reference to the [`GridSearchConfig`] struct.
///
/// Returns a vector of [`GridSearchResult`] structs.
pub fn run_mean_grid(candles: &[Candle], config: &GridSearchConfig) -> Vec<GridSearchResult> {
    let mut results = Vec::new();

    for &ma_period in &config.ma_periods {
        for &entry_threshold in &config.entry_thresholds {
            for &exit_threshold in &config.exit_thresholds {
                for &stop_loss in &config.stop_losses {
                    let params = MeanReversionParams {
                        ma_period,
                        entry_threshold,
                        exit_threshold,
                        stop_loss,
                    };

                    let start = Instant::now();
                    let trades = run_mean_reversion(candles, &params);
                    let duration_ms = start.elapsed().as_millis();

                    let bt_stats = stats::calculate_backtest_stats(&trades);
                    let (status, reason_flagged) = flag_result(
                        &bt_stats,
                        "mean_reversion",
                        trades.last().map(|t| t.exit_time),
                    );

                    results.push(GridSearchResult {
                        strategy_type: "mean_reversion".to_string(),
                        strategy_name: format!("MeanReversion_MA{}", ma_period),
                        params_json: serde_json::json!({
                            "ma_period": ma_period,
                            "entry_threshold": entry_threshold,
                            "exit_threshold": exit_threshold,
                            "stop_loss": stop_loss,
                        }),
                        stats: bt_stats,
                        trades,
                        status,
                        reason_flagged,
                        duration_ms,
                    });
                }
            }
        }
    }

    results
}

pub fn run_trend_grid(candles: &[Candle], config: &TrendGridConfig) -> Vec<GridSearchResult> {
    let mut results = Vec::new();

    for &fast in &config.fast_periods {
        for &slow in &config.slow_periods {
            if fast >= slow {
                continue;
            }

            for &stop_loss in &config.stop_losses {
                for take_profit in &config.take_profits {
                    let params = TrendFollowingParams {
                        fast_period: fast,
                        slow_period: slow,
                        stop_loss,
                        take_profit: *take_profit,
                    };

                    let start = Instant::now();
                    let trades = run_trend_following(candles, &params);
                    let duration_ms = start.elapsed().as_millis();

                    let bt_stats = stats::calculate_backtest_stats(&trades);
                    let (status, reason_flagged) = flag_result(
                        &bt_stats,
                        "trend_following",
                        trades.last().map(|t| t.exit_time),
                    );

                    results.push(GridSearchResult {
                        strategy_type: "trend_following".to_string(),
                        strategy_name: format!("TrendFollow_F{}_S{}", fast, slow),
                        params_json: serde_json::json!({
                            "fast_period": fast,
                            "slow_period": slow,
                            "stop_loss": stop_loss,
                            "take_profit": take_profit,
                        }),
                        stats: bt_stats,
                        trades,
                        status,
                        reason_flagged,
                        duration_ms,
                    });
                }
            }
        }
    }

    results
}

/// Converts an [`EntryReason`] enum variant to a string.
///
/// Parameters:
/// - `reason`: A reference to the [`EntryReason`] enum variant.
///
/// Returns a string representation of the entry reason.
fn entry_reason_to_string(reason: &EntryReason) -> String {
    match reason {
        EntryReason::BelowMA { .. } => "BelowMA".to_string(),
        EntryReason::CrossAbove { .. } => "CrossAbove".to_string(),
        EntryReason::CrossBelow { .. } => "CrossBelow".to_string(),
    }
}

/// Converts an [`ExitReason`] enum variant to a string.
///
/// Parameters:
/// - `reason`: A reference to the [`ExitReason`] enum variant.
///
/// Returns a string representation of the exit reason.
fn exit_reason_to_string(reason: &ExitReason) -> String {
    match reason {
        ExitReason::TakeProfit => "TakeProfit".to_string(),
        ExitReason::StopLoss => "StopLoss".to_string(),
        ExitReason::TimeExit => "TimeExit".to_string(),
        ExitReason::EndOfData => "EndOfData".to_string(),
        ExitReason::TrendReversal => "TrendReversal".to_string(),
    }
}

/// Converts an [`EntryReason`] enum variant to a JSON value.
///
/// Parameters:
/// - `reason`: A reference to the [`EntryReason`] enum variant.
///
/// Returns a [`serde_json::Value`] representation of the entry reason.
fn entry_reason_to_json(reason: &EntryReason) -> serde_json::Value {
    match reason {
        EntryReason::BelowMA {
            ma_value,
            deviation_pct,
        } => {
            serde_json::json!({
                "ma_value": ma_value,
                "deviation_pct": deviation_pct,
            })
        }
        EntryReason::CrossAbove { fast_ma, slow_ma } => {
            serde_json::json!({
                "fast_ma": fast_ma,
                "slow_ma": slow_ma,
            })
        }
        EntryReason::CrossBelow { fast_ma, slow_ma } => {
            serde_json::json!({
                "fast_ma": fast_ma,
                "slow_ma": slow_ma,
            })
        }
    }
}

/// Stores the results of a grid search in the database.
///
/// Parameters:
/// - `pool`: A reference to the database connection pool.
/// - `config`: A reference to the [`GridSearchConfig`] struct.
/// - `results`: A slice of [`GridSearchResult`] structs.
///
/// Returns the number of results stored.
pub async fn store_results(
    pool: &PgPool,
    instrument: &str,
    granularity: &str,
    results: &[GridSearchResult],
) -> Result<usize, sqlx::Error> {
    let mut count = 0;

    for result in results {
        let run_id = Uuid::new_v4();

        let start_date = result
            .trades
            .first()
            .map(|t| t.entry_time)
            .unwrap_or_else(Utc::now);
        let end_date = result
            .trades
            .last()
            .map(|t| t.exit_time)
            .unwrap_or_else(Utc::now);

        sqlx::query(
            r#"
            INSERT INTO backtest_runs
                (id, strategy_name, strategy_type, instrument, granularity, parameters,
                 start_date, end_date, total_return, win_rate, sharpe_ratio, max_drawdown,
                 num_trades, avg_win, avg_loss, status, reason_flagged, execution_duration_ms)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18)
            "#,
        )
        .bind(run_id)
        .bind(&result.strategy_name)
        .bind(&result.strategy_type)
        .bind(instrument)
        .bind(granularity)
        .bind(&result.params_json)
        .bind(start_date)
        .bind(end_date)
        .bind(result.stats.total_return)
        .bind(result.stats.win_rate)
        .bind(result.stats.sharpe_ratio)
        .bind(result.stats.max_drawdown)
        .bind(result.stats.num_trades as i32)
        .bind(result.stats.avg_win)
        .bind(result.stats.avg_loss)
        .bind(&result.status)
        .bind(&result.reason_flagged)
        .bind(result.duration_ms as i32)
        .execute(pool)
        .await?;

        if result.status != "failed" {
            for trade in &result.trades {
                sqlx::query(
                    r#"
                    INSERT INTO backtest_trades
                        (backtest_run_id, entry_price, exit_price, entry_time, exit_time,
                         pnl_percent, entry_reason, exit_reason, entry_details)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
                    "#,
                )
                .bind(run_id)
                .bind(trade.entry_price)
                .bind(trade.exit_price)
                .bind(trade.entry_time)
                .bind(trade.exit_time)
                .bind(trade.pnl_percent)
                .bind(entry_reason_to_string(&trade.entry_reason))
                .bind(exit_reason_to_string(&trade.exit_reason))
                .bind(entry_reason_to_json(&trade.entry_reason))
                .execute(pool)
                .await?;
            }

            count += 1;
        }
    }

    Ok(count)
}
