use anyhow::Context;
use auro::config::Config;
use auro::db::create_pool;
use auro::oanda::client::OandaClient;
use serde_json::Value;
use sqlx::PgPool;

#[derive(Debug)]
struct ClosedTrade {
    oanda_trade_id: String,
    strategy_type: Option<String>,
    entry_price: f64,
}

async fn load_trades_needing_backfill(pool: &PgPool) -> anyhow::Result<Vec<ClosedTrade>> {
    let rows: Vec<(Option<String>, Option<String>, Option<f64>)> = sqlx::query_as(
        "SELECT lt.oanda_trade_id, ls.strategy_type, lt.entry_price \
         FROM live_trades lt \
         LEFT JOIN live_strategies ls ON ls.id = lt.live_strategy_id \
         WHERE lt.status = 'closed' AND lt.stop_loss_state_at_close IS NULL \
           AND lt.oanda_trade_id IS NOT NULL AND lt.entry_price IS NOT NULL \
         ORDER BY lt.exit_time ASC",
    )
    .fetch_all(pool)
    .await
    .context("failed to load trades needing stop_loss_state backfill")?;

    Ok(rows
        .into_iter()
        .filter_map(|(id, st, ep)| {
            Some(ClosedTrade {
                oanda_trade_id: id?,
                strategy_type: st,
                entry_price: ep?,
            })
        })
        .collect())
}

// Mirrors auro_be/src/engine/live/prefill.rs::determine_stop_loss_state
// so backfilled rows match what live writes.
fn infer_state(trade: &Value, strategy_type: &str, entry_price: f64) -> &'static str {
    match strategy_type {
        "trend_following" => {}
        _ => return "NotApplicable",
    }

    if trade.get("trailingStopLossOrder").is_some() {
        return "Trailing";
    }

    if let Some(sl) = trade.get("stopLossOrder") {
        if let Some(sl_price) = sl["price"].as_str().and_then(|s| s.parse::<f64>().ok()) {
            if entry_price > 0.0 && (sl_price - entry_price).abs() / entry_price < 0.0001 {
                return "Breakeven";
            }
        }
    }

    "Initial"
}

async fn update_state(pool: &PgPool, trade_id: &str, state: &str) -> anyhow::Result<()> {
    sqlx::query(
        "UPDATE live_trades SET stop_loss_state_at_close = $1, updated_at = NOW() \
         WHERE oanda_trade_id = $2 AND status = 'closed' AND stop_loss_state_at_close IS NULL",
    )
    .bind(state)
    .bind(trade_id)
    .execute(pool)
    .await
    .with_context(|| format!("failed to update {}", trade_id))?;
    Ok(())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    let config = Config::from_env().context("failed to load env config")?;
    let pool = create_pool(&config.database_url)
        .await
        .context("failed to connect db")?;

    let oanda = OandaClient::new(
        &config.oanda_base_url,
        &config.oanda_stream_url,
        &config.oanda_api_key,
        &config.oanda_account_id,
    );

    let trades = load_trades_needing_backfill(&pool).await?;

    if trades.is_empty() {
        println!("No closed trades need stop_loss_state_at_close backfill.");
        return Ok(());
    }

    println!(
        "Found {} closed trades needing stop_loss_state_at_close backfill",
        trades.len()
    );

    let mut not_applicable = 0usize;
    let mut from_oanda = 0usize;
    let mut aged_out = 0usize;
    let mut oanda_errors = 0usize;
    let mut unknown_strategy = 0usize;

    for trade in &trades {
        let strategy_type = trade.strategy_type.as_deref().unwrap_or("");

        // Non trend-following (or unknown strategy) -> NotApplicable, no OANDA call needed.
        if strategy_type != "trend_following" {
            if strategy_type.is_empty() {
                unknown_strategy += 1;
            }
            update_state(&pool, &trade.oanda_trade_id, "NotApplicable").await?;
            not_applicable += 1;
            continue;
        }

        match oanda.get_trade(&trade.oanda_trade_id).await {
            Ok(envelope) => {
                let Some(trade_obj) = envelope.get("trade") else {
                    println!(
                        "  [skip] {}: OANDA response missing 'trade' envelope",
                        trade.oanda_trade_id
                    );
                    oanda_errors += 1;
                    continue;
                };

                let state = infer_state(trade_obj, strategy_type, trade.entry_price);
                update_state(&pool, &trade.oanda_trade_id, state).await?;
                from_oanda += 1;
            }
            Err(e) => {
                let msg = e.to_string();
                if msg.contains("HTTP 404") {
                    aged_out += 1;
                } else {
                    println!("  [oanda-err] {}: {}", trade.oanda_trade_id, msg);
                    oanda_errors += 1;
                }
            }
        }
    }

    println!("\nNotApplicable (non-trend-following): {}", not_applicable);
    if unknown_strategy > 0 {
        println!(
            "  (of which {} had no strategy_type linked)",
            unknown_strategy
        );
    }
    println!("Inferred from OANDA trade snapshot:   {}", from_oanda);
    println!("Aged out of OANDA (left NULL):        {}", aged_out);
    println!("OANDA errors (left NULL):             {}", oanda_errors);

    let remaining: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM live_trades \
         WHERE status = 'closed' AND stop_loss_state_at_close IS NULL",
    )
    .fetch_one(&pool)
    .await
    .context("failed counting remaining NULL stop_loss_state rows")?;

    println!(
        "\nRemaining NULL stop_loss_state_at_close rows: {}",
        remaining
    );

    Ok(())
}
