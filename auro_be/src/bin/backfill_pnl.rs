use std::collections::HashMap;

use anyhow::Context;
use auro::brokers::oanda::client::OandaClient;
use auro::config::Config;
use auro::db::create_pool;

fn parse_trade_realized_pl_from_tx(tx: &serde_json::Value, out: &mut HashMap<String, f64>) {
    if tx.get("type").and_then(|v| v.as_str()) != Some("ORDER_FILL") {
        return;
    }

    let Some(closed) = tx.get("tradesClosed").and_then(|v| v.as_array()) else {
        return;
    };

    for entry in closed {
        let Some(trade_id) = entry.get("tradeID").and_then(|v| v.as_str()) else {
            continue;
        };
        let Some(realized) = entry
            .get("realizedPL")
            .and_then(|v| v.as_str())
            .and_then(|s| s.parse::<f64>().ok())
        else {
            continue;
        };

        out.insert(trade_id.to_string(), realized);
    }
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

    let trade_ids: Vec<String> = sqlx::query_scalar(
        "SELECT oanda_trade_id FROM live_trades \
         WHERE status = 'closed' AND pnl IS NULL AND oanda_trade_id IS NOT NULL",
    )
    .fetch_all(&pool)
    .await
    .context("failed to load trades needing pnl backfill")?;

    if trade_ids.is_empty() {
        println!("No closed trades with NULL pnl. Nothing to backfill.");
        return Ok(());
    }

    println!("Found {} closed trades with NULL pnl", trade_ids.len());

    let mut realized_by_trade: HashMap<String, f64> = HashMap::new();
    let mut since_id = String::from("1");
    let mut pages = 0usize;

    loop {
        pages += 1;
        let resp = oanda
            .list_transactions_since(&since_id)
            .await
            .with_context(|| format!("failed fetching transactions since {}", since_id))?;

        if let Some(transactions) = resp.get("transactions").and_then(|v| v.as_array()) {
            for tx in transactions {
                parse_trade_realized_pl_from_tx(tx, &mut realized_by_trade);
            }
        }

        let Some(last_id) = resp
            .get("lastTransactionID")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
        else {
            break;
        };

        if last_id == since_id {
            break;
        }
        since_id = last_id;

        if pages > 10_000 {
            anyhow::bail!("aborting after too many transaction pages");
        }
    }

    println!(
        "Indexed realized P&L for {} trades from OANDA ORDER_FILL transactions",
        realized_by_trade.len()
    );

    let mut updated = 0usize;
    let mut missing = 0usize;

    for trade_id in &trade_ids {
        let Some(realized) = realized_by_trade.get(trade_id) else {
            missing += 1;
            continue;
        };

        let result = sqlx::query(
            "UPDATE live_trades SET pnl = $1, updated_at = NOW() \
             WHERE oanda_trade_id = $2 AND status = 'closed' AND pnl IS NULL",
        )
        .bind(realized)
        .bind(trade_id)
        .execute(&pool)
        .await
        .with_context(|| format!("failed updating pnl for trade {}", trade_id))?;

        updated += result.rows_affected() as usize;
    }

    let remaining_null: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM live_trades WHERE status = 'closed' AND pnl IS NULL",
    )
    .fetch_one(&pool)
    .await
    .context("failed counting remaining NULL pnl rows")?;

    println!("Updated {} trades", updated);
    println!("Missing from OANDA tx index {} trades", missing);
    println!("Remaining NULL pnl rows: {}", remaining_null);

    Ok(())
}
