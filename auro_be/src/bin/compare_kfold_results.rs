use anyhow::Context;
use auro::config::Config;
use auro::db::create_pool;

#[derive(Debug, Clone, sqlx::FromRow)]
struct ComparisonRow {
    instrument: String,
    granularity: String,
    strategy_type: String,
    old_median_sharpe: f64,
    new_median_sharpe: f64,
    delta: f64,
    new_pass_rate: f64,
    demote_candidate: bool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    let config = Config::from_env().context("failed to load env config")?;
    let pool = create_pool(&config.database_url)
        .await
        .context("failed to connect db")?;

    let rows: Vec<ComparisonRow> = sqlx::query_as(
        r#"
        WITH ranked AS (
            SELECT
                kv.live_strategy_id,
                kv.median_sharpe,
                kv.pass_rate,
                kv.validated_at,
                ROW_NUMBER() OVER (
                    PARTITION BY kv.live_strategy_id
                    ORDER BY kv.validated_at DESC
                ) AS rn
            FROM kfold_validations kv
        ),
        paired AS (
            SELECT
                live_strategy_id,
                MAX(CASE WHEN rn = 1 THEN median_sharpe END) AS new_median_sharpe,
                MAX(CASE WHEN rn = 2 THEN median_sharpe END) AS old_median_sharpe,
                MAX(CASE WHEN rn = 1 THEN pass_rate END) AS new_pass_rate
            FROM ranked
            WHERE rn <= 2
            GROUP BY live_strategy_id
            HAVING COUNT(*) = 2
        )
        SELECT
            ls.instrument,
            ls.granularity,
            ls.strategy_type,
            p.old_median_sharpe,
            p.new_median_sharpe,
            (p.new_median_sharpe - p.old_median_sharpe) AS delta,
            p.new_pass_rate,
            (p.new_pass_rate < 0.80 OR (p.old_median_sharpe - p.new_median_sharpe) > 0.10) AS demote_candidate
        FROM paired p
        JOIN live_strategies ls ON ls.id = p.live_strategy_id
        ORDER BY demote_candidate DESC, delta ASC, ls.instrument, ls.granularity, ls.strategy_type
        "#,
    )
    .fetch_all(&pool)
    .await
    .context("failed querying latest two k-fold results per strategy")?;

    if rows.is_empty() {
        println!(
            "No comparable k-fold result pairs found (need at least two validations per strategy)."
        );
        return Ok(());
    }

    println!(
        "{:<32} {:>18} {:>18} {:>10} {:>16} {:>10}",
        "Strategy", "Old median_sharpe", "New median_sharpe", "Delta", "New pass_rate", "Candidate"
    );

    for row in rows {
        let label = format!(
            "{} {} {}",
            row.instrument, row.granularity, row.strategy_type
        );
        println!(
            "{:<32} {:>18.2} {:>18.2} {:>10.2} {:>15.0}% {:>10}",
            label,
            row.old_median_sharpe,
            row.new_median_sharpe,
            row.delta,
            row.new_pass_rate * 100.0,
            if row.demote_candidate { "YES" } else { "NO" }
        );
    }

    Ok(())
}
