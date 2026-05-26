use chrono::{DateTime, Utc};

use crate::engine::pipeline::{run_backtest_stats, StrategyConfig};
use crate::engine::stats::BacktestStats;
use crate::engine::types::Candle;

#[derive(Debug, Clone)]
pub struct KFoldSpec {
    pub n_folds: usize,
    pub warmup_candles: usize,
    pub min_test_candles: usize,
}

impl Default for KFoldSpec {
    fn default() -> Self {
        Self {
            n_folds: 8,
            warmup_candles: 200,
            min_test_candles: 100,
        }
    }
}

#[derive(Debug, Clone)]
pub struct TestWindow {
    pub fold_index: usize,
    pub start_idx: usize,
    pub end_idx: usize,
    pub start_time: DateTime<Utc>,
    pub end_time: DateTime<Utc>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct FoldResult {
    pub fold_index: usize,
    pub start_time: DateTime<Utc>,
    pub end_time: DateTime<Utc>,
    pub stats: BacktestStats,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct KFoldAggregate {
    pub fold_count: usize,
    pub pass_count: usize,
    pub pass_rate: f64,
    pub median_sharpe: f64,
    pub mean_sharpe: f64,
    pub sharpe_std: f64,
    pub min_sharpe: f64,
    pub max_sharpe: f64,
    pub worst_fold_dd: f64,
    pub median_dd: f64,
    pub total_trades_all_folds: usize,
    pub per_fold: Vec<FoldResult>,
}

pub fn build_test_windows(candles: &[Candle], spec: &KFoldSpec) -> Vec<TestWindow> {
    if candles.is_empty() || spec.n_folds == 0 {
        return vec![];
    }

    let mut windows = Vec::new();
    let n = candles.len();

    for fold_index in 0..spec.n_folds {
        let start_idx = fold_index * n / spec.n_folds;
        let end_idx = (fold_index + 1) * n / spec.n_folds;

        if end_idx <= start_idx {
            continue;
        }

        if end_idx - start_idx < spec.min_test_candles {
            continue;
        }

        windows.push(TestWindow {
            fold_index,
            start_idx,
            end_idx,
            start_time: candles[start_idx].time,
            end_time: candles[end_idx - 1].time,
        });
    }

    windows
}

pub fn run_kfold(
    strategy: &StrategyConfig,
    candles: &[Candle],
    windows: &[TestWindow],
) -> Vec<FoldResult> {
    run_kfold_with_warmup(
        strategy,
        candles,
        windows,
        KFoldSpec::default().warmup_candles,
    )
}

pub fn run_kfold_with_warmup(
    strategy: &StrategyConfig,
    candles: &[Candle],
    windows: &[TestWindow],
    warmup_candles: usize,
) -> Vec<FoldResult> {
    let mut out = Vec::new();

    for w in windows {
        if w.end_idx > candles.len() || w.start_idx >= w.end_idx {
            continue;
        }

        let slice_start = w.start_idx.saturating_sub(warmup_candles);
        let local_active_start_idx = w.start_idx - slice_start;
        let fold_slice = &candles[slice_start..w.end_idx];

        match run_backtest_stats(fold_slice, strategy, Some(local_active_start_idx)) {
            Ok(stats) => out.push(FoldResult {
                fold_index: w.fold_index,
                start_time: w.start_time,
                end_time: w.end_time,
                stats,
            }),
            Err(e) => {
                tracing::warn!(
                    "[KFOLD] fold {} {} {} skipped due to backtest error: {}",
                    w.fold_index,
                    strategy.instrument,
                    strategy.granularity,
                    e
                );
            }
        }
    }

    out
}

pub fn aggregate(results: &[FoldResult]) -> KFoldAggregate {
    if results.is_empty() {
        return KFoldAggregate {
            fold_count: 0,
            pass_count: 0,
            pass_rate: 0.0,
            median_sharpe: 0.0,
            mean_sharpe: 0.0,
            sharpe_std: 0.0,
            min_sharpe: 0.0,
            max_sharpe: 0.0,
            worst_fold_dd: 0.0,
            median_dd: 0.0,
            total_trades_all_folds: 0,
            per_fold: vec![],
        };
    }

    let fold_count = results.len();
    let sharpe_values: Vec<f64> = results.iter().map(|r| r.stats.sharpe_ratio).collect();
    let dd_values: Vec<f64> = results.iter().map(|r| r.stats.max_drawdown.abs()).collect();

    let pass_count = results
        .iter()
        .filter(|r| r.stats.sharpe_ratio > 0.0 && r.stats.total_return > 0.0)
        .count();

    let total_trades_all_folds = results.iter().map(|r| r.stats.num_trades).sum();

    let mean_sharpe = mean(&sharpe_values);
    let sharpe_std = stddev(&sharpe_values, mean_sharpe);

    KFoldAggregate {
        fold_count,
        pass_count,
        pass_rate: pass_count as f64 / fold_count as f64,
        median_sharpe: median(&sharpe_values),
        mean_sharpe,
        sharpe_std,
        min_sharpe: sharpe_values
            .iter()
            .copied()
            .min_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal))
            .unwrap_or(0.0),
        max_sharpe: sharpe_values
            .iter()
            .copied()
            .max_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal))
            .unwrap_or(0.0),
        worst_fold_dd: dd_values
            .iter()
            .copied()
            .max_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal))
            .unwrap_or(0.0),
        median_dd: median(&dd_values),
        total_trades_all_folds,
        per_fold: results.to_vec(),
    }
}

fn mean(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    values.iter().sum::<f64>() / values.len() as f64
}

fn stddev(values: &[f64], mean_value: f64) -> f64 {
    if values.is_empty() {
        return 0.0;
    }

    let variance = values
        .iter()
        .map(|v| {
            let d = v - mean_value;
            d * d
        })
        .sum::<f64>()
        / values.len() as f64;

    variance.sqrt()
}

fn median(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }

    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

    let mid = sorted.len() / 2;
    if sorted.len().is_multiple_of(2) {
        (sorted[mid - 1] + sorted[mid]) / 2.0
    } else {
        sorted[mid]
    }
}

#[cfg(test)]
mod tests {
    use chrono::{Duration, Utc};
    use serde_json::json;
    use uuid::Uuid;

    use crate::engine::pipeline::StrategyConfig;
    use crate::engine::stats::BacktestStats;
    use crate::engine::types::{Candle, Granularity, OHLC};

    use super::{aggregate, build_test_windows, FoldResult, KFoldSpec};

    fn make_candles(n: usize) -> Vec<Candle> {
        let start = Utc::now() - Duration::hours(n as i64);
        (0..n)
            .map(|i| Candle {
                time: start + Duration::hours(i as i64),
                mid: OHLC {
                    open: 1.0 + i as f64 * 0.0001,
                    high: 1.001 + i as f64 * 0.0001,
                    low: 0.999 + i as f64 * 0.0001,
                    close: 1.0 + i as f64 * 0.0001,
                },
                volume: 100,
                bid: None,
                ask: None,
            })
            .collect()
    }

    #[test]
    fn build_test_windows_creates_n_folds_for_clean_data() {
        let candles = make_candles(8000);
        let spec = KFoldSpec {
            n_folds: 8,
            warmup_candles: 200,
            min_test_candles: 100,
        };
        let windows = build_test_windows(&candles, &spec);
        assert_eq!(windows.len(), 8);
        assert_eq!(windows[0].start_idx, 0);
        assert_eq!(windows[7].end_idx, 8000);
    }

    #[test]
    fn build_test_windows_skips_too_short_folds() {
        let candles = make_candles(500);
        let spec = KFoldSpec {
            n_folds: 8,
            warmup_candles: 200,
            min_test_candles: 100,
        };
        let windows = build_test_windows(&candles, &spec);
        assert!(windows.is_empty() || windows.len() < 8);
    }

    #[test]
    fn aggregate_computes_median_correctly() {
        let now = Utc::now();
        let make = |fold_index: usize, sharpe: f64| FoldResult {
            fold_index,
            start_time: now,
            end_time: now,
            stats: BacktestStats {
                total_return: if sharpe > 0.0 { 0.1 } else { -0.1 },
                win_rate: 0.5,
                avg_win: 0.01,
                avg_loss: -0.01,
                max_drawdown: -0.05,
                sharpe_ratio: sharpe,
                num_trades: 10,
            },
        };

        let agg = aggregate(&[make(0, -1.0), make(1, 0.0), make(2, 1.0), make(3, 2.0)]);
        assert_eq!(agg.fold_count, 4);
        assert!((agg.median_sharpe - 0.5).abs() < 1e-12);
        assert!((agg.mean_sharpe - 0.5).abs() < 1e-12);
        assert!(agg.sharpe_std > 1.0);
    }

    #[tokio::test]
    #[ignore = "requires DB and candles"]
    async fn full_kfold_run_against_real_strategy() {
        let _dummy = StrategyConfig {
            id: Uuid::new_v4(),
            instrument: "EUR_USD".to_string(),
            granularity: Granularity::H1,
            strategy_type: "mean_reversion".to_string(),
            parameters: json!({
                "ma_period": 20,
                "entry_threshold": 0.01,
                "exit_threshold": 0.005,
                "stop_loss": -0.02,
                "regime_filter": true
            }),
        };
    }
}
