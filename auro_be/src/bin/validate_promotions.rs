use std::env;

use anyhow::Context;
use auro::config::Config;
use auro::db::create_pool;
use auro::engine::grid::load_candles;
use auro::engine::kfold::{aggregate, build_test_windows, run_kfold_with_warmup, KFoldSpec};
use auro::engine::pipeline::StrategyConfig;
use auro::engine::types::Granularity;
use chrono::Utc;
use serde_json::{json, Value};
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, Clone)]
struct CliArgs {
    folds: usize,
    write_db: bool,
    filter_enabled: Option<bool>,
}

#[derive(Debug, Clone)]
struct LiveStrategyRow {
    id: Uuid,
    strategy_type: String,
    instrument: String,
    granularity: Granularity,
    parameters: Value,
    enabled: bool,
}

#[derive(Debug, Clone)]
struct StrategySummary {
    strategy: LiveStrategyRow,
    agg: auro::engine::kfold::KFoldAggregate,
}

fn parse_args() -> anyhow::Result<CliArgs> {
    let mut folds = 8usize;
    let mut write_db = false;
    let mut filter_enabled: Option<bool> = None;

    let mut iter = env::args().skip(1);
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--folds" => {
                let value = iter.next().context("--folds requires an integer value")?;
                folds = value
                    .parse::<usize>()
                    .with_context(|| format!("invalid --folds value: {}", value))?;
            }
            "--write-db" => {
                write_db = true;
            }
            "--filter" => {
                let value = iter
                    .next()
                    .context("--filter requires a value, e.g. enabled=true")?;
                filter_enabled = match value.as_str() {
                    "enabled=true" => Some(true),
                    "enabled=false" => Some(false),
                    "all" => None,
                    other => {
                        anyhow::bail!(
                            "unsupported --filter value '{}'; expected enabled=true, enabled=false, or all",
                            other
                        )
                    }
                };
            }
            "--help" | "-h" => {
                println!(
                    "Usage: validate_promotions [--folds N] [--write-db] [--filter enabled=true|enabled=false|all]"
                );
                std::process::exit(0);
            }
            other => {
                anyhow::bail!("unknown argument: {}", other);
            }
        }
    }

    Ok(CliArgs {
        folds,
        write_db,
        filter_enabled,
    })
}

async fn load_live_strategies(
    pool: &PgPool,
    filter_enabled: Option<bool>,
) -> anyhow::Result<Vec<LiveStrategyRow>> {
    let rows: Vec<(Uuid, String, String, String, Value, bool)> = sqlx::query_as(
        r#"
        SELECT id, strategy_type, instrument, granularity, parameters, enabled
        FROM live_strategies
        WHERE ($1::bool IS NULL OR enabled = $1)
        ORDER BY instrument, granularity, strategy_type
        "#,
    )
    .bind(filter_enabled)
    .fetch_all(pool)
    .await
    .context("failed loading live_strategies")?;

    let mut out = Vec::with_capacity(rows.len());
    for (id, strategy_type, instrument, granularity_str, parameters, enabled) in rows {
        let granularity = granularity_str.parse::<Granularity>().map_err(|e| {
            anyhow::anyhow!(
                "invalid granularity '{}' for {}: {}",
                granularity_str,
                id,
                e
            )
        })?;

        out.push(LiveStrategyRow {
            id,
            strategy_type,
            instrument,
            granularity,
            parameters,
            enabled,
        });
    }

    Ok(out)
}

async fn insert_kfold_validation(
    pool: &PgPool,
    strategy: &LiveStrategyRow,
    spec: &KFoldSpec,
    agg: &auro::engine::kfold::KFoldAggregate,
) -> anyhow::Result<()> {
    let per_fold_stats = json!({ "folds": agg.per_fold });
    let spec_json = json!({
        "n_folds": spec.n_folds,
        "warmup_candles": spec.warmup_candles,
        "min_test_candles": spec.min_test_candles,
    });

    sqlx::query(
        r#"
        INSERT INTO kfold_validations (
            id,
            live_strategy_id,
            fold_count,
            pass_rate,
            median_sharpe,
            mean_sharpe,
            sharpe_std,
            min_sharpe,
            max_sharpe,
            worst_fold_dd,
            median_dd,
            total_trades_all_folds,
            per_fold_stats,
            spec,
            validated_at
        )
        VALUES (
            gen_random_uuid(),
            $1,
            $2,
            $3,
            $4,
            $5,
            $6,
            $7,
            $8,
            $9,
            $10,
            $11,
            $12,
            $13,
            NOW()
        )
        "#,
    )
    .bind(strategy.id)
    .bind(agg.fold_count as i32)
    .bind(agg.pass_rate)
    .bind(agg.median_sharpe)
    .bind(agg.mean_sharpe)
    .bind(agg.sharpe_std)
    .bind(agg.min_sharpe)
    .bind(agg.max_sharpe)
    .bind(agg.worst_fold_dd)
    .bind(agg.median_dd)
    .bind(agg.total_trades_all_folds as i32)
    .bind(per_fold_stats)
    .bind(spec_json)
    .execute(pool)
    .await
    .with_context(|| {
        format!(
            "failed inserting kfold_validations for strategy {}",
            strategy.id
        )
    })?;

    Ok(())
}

fn print_summary(rows: &[StrategySummary]) {
    if rows.is_empty() {
        println!("\nNo strategy summaries to print.");
        return;
    }

    let mut by_pass = rows.to_vec();
    by_pass.sort_by(|a, b| {
        b.agg
            .pass_rate
            .partial_cmp(&a.agg.pass_rate)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                b.agg
                    .median_sharpe
                    .partial_cmp(&a.agg.median_sharpe)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
    });

    let mut by_sharpe = rows.to_vec();
    by_sharpe.sort_by(|a, b| {
        b.agg
            .median_sharpe
            .partial_cmp(&a.agg.median_sharpe)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let mut failed: Vec<StrategySummary> = rows
        .iter()
        .filter(|r| r.agg.fold_count > 0 && r.agg.pass_rate < 0.50)
        .cloned()
        .collect();

    failed.sort_by(|a, b| {
        a.agg
            .pass_rate
            .partial_cmp(&b.agg.pass_rate)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                a.agg
                    .median_sharpe
                    .partial_cmp(&b.agg.median_sharpe)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
    });

    println!("\n=== TOP 20 BY PASS RATE ===");
    for row in by_pass.iter().take(20) {
        println!(
            "  {:<10} {:<3} {:<16} pass={}/{}  median_sharpe={:.2}",
            row.strategy.instrument,
            row.strategy.granularity,
            row.strategy.strategy_type,
            row.agg.pass_count,
            row.agg.fold_count,
            row.agg.median_sharpe
        );
    }

    println!("\n=== TOP 20 BY MEDIAN SHARPE ===");
    for row in by_sharpe.iter().take(20) {
        println!(
            "  {:<10} {:<3} {:<16} pass={}/{}  median_sharpe={:.2}",
            row.strategy.instrument,
            row.strategy.granularity,
            row.strategy.strategy_type,
            row.agg.pass_count,
            row.agg.fold_count,
            row.agg.median_sharpe
        );
    }

    println!("\n=== FAILED (pass_rate < 50%) ===");
    for row in failed.iter().take(10) {
        println!(
            "  {:<10} {:<3} {:<16} pass={}/{}  median_sharpe={:.2}",
            row.strategy.instrument,
            row.strategy.granularity,
            row.strategy.strategy_type,
            row.agg.pass_count,
            row.agg.fold_count,
            row.agg.median_sharpe
        );
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    let args = parse_args()?;
    let config = Config::from_env().context("failed to load env config")?;
    let pool = create_pool(&config.database_url)
        .await
        .context("failed to connect db")?;

    let spec = KFoldSpec {
        n_folds: args.folds,
        ..KFoldSpec::default()
    };

    let strategies = load_live_strategies(&pool, args.filter_enabled).await?;
    if strategies.is_empty() {
        println!("No live strategies found for the requested filter.");
        return Ok(());
    }

    println!(
        "Running k-fold validation for {} strategies (folds={}, warmup={}, min_test={})",
        strategies.len(),
        spec.n_folds,
        spec.warmup_candles,
        spec.min_test_candles
    );

    let mut summaries: Vec<StrategySummary> = Vec::new();
    let mut db_inserts = 0usize;

    for (idx, row) in strategies.iter().enumerate() {
        let strategy = StrategyConfig {
            id: row.id,
            instrument: row.instrument.clone(),
            granularity: row.granularity,
            strategy_type: row.strategy_type.clone(),
            parameters: row.parameters.clone(),
        };

        let candles = match load_candles(&pool, &row.instrument, row.granularity.as_str()).await {
            Ok(c) => c,
            Err(e) => {
                println!(
                    "[{:>3}/{}] {} {} {} ... SKIP (load candles failed: {})",
                    idx + 1,
                    strategies.len(),
                    row.instrument,
                    row.granularity,
                    row.strategy_type,
                    e
                );
                continue;
            }
        };

        let windows = build_test_windows(&candles, &spec);
        if windows.is_empty() {
            println!(
                "[{:>3}/{}] {} {} {} ... SKIP (insufficient candles: {})",
                idx + 1,
                strategies.len(),
                row.instrument,
                row.granularity,
                row.strategy_type,
                candles.len()
            );
            continue;
        }

        let results = run_kfold_with_warmup(&strategy, &candles, &windows, spec.warmup_candles);
        let agg = aggregate(&results);

        println!(
            "[{:>3}/{}] {} {} {} (enabled={}) ... pass_rate={:.2} median_sharpe={:.2} worst_dd={:.1}%",
            idx + 1,
            strategies.len(),
            row.instrument,
            row.granularity,
            row.strategy_type,
            row.enabled,
            agg.pass_rate,
            agg.median_sharpe,
            agg.worst_fold_dd * 100.0
        );

        if args.write_db && agg.fold_count > 0 {
            if let Err(e) = insert_kfold_validation(&pool, row, &spec, &agg).await {
                tracing::warn!(
                    "[KFOLD] failed writing kfold_validations for strategy {}: {}",
                    row.id,
                    e
                );
            } else {
                db_inserts += 1;
            }
        }

        summaries.push(StrategySummary {
            strategy: row.clone(),
            agg,
        });
    }

    println!(
        "\nCompleted at {}. Processed {} strategies, produced {} summaries, wrote {} DB rows.",
        Utc::now(),
        strategies.len(),
        summaries.len(),
        db_inserts
    );

    print_summary(&summaries);

    Ok(())
}
