//! Vendor smoke test for the option contract listing and one contract's
//! daily bars. Reads MASSIVE_API_KEY; writes nothing.
//!   cargo run --example options_smoke -- SPY
use chrono::{Duration, Utc};

use auro::brokers::massive::client::{ContractFilter, MassiveClient};
use auro::engine::options::{implied_vol, OptionKind};
use auro::engine::types::Granularity;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    dotenvy::dotenv().ok();
    let underlying = std::env::args().nth(1).unwrap_or_else(|| "SPY".into());
    let key = std::env::var("MASSIVE_API_KEY")?;
    let client = MassiveClient::new("https://api.massive.com", &key, 5)?;
    let today = Utc::now().date_naive();
    let filter = ContractFilter {
        underlying: underlying.clone(),
        expires_from: today,
        expires_to: today + Duration::days(10),
        strikes: None,
        expired: false,
        as_of: None,
    };
    let contracts = client.list_option_contracts(&filter).await?;
    println!(
        "{} contracts on {} expiring within 10 days",
        contracts.len(),
        underlying
    );
    let expiries: std::collections::BTreeSet<_> =
        contracts.iter().map(|c| c.expiration_date).collect();
    println!("expiries: {:?}", expiries);
    // pick a call near the middle of the strike range at the nearest expiry
    let first = *expiries.iter().next().unwrap();
    let mut calls: Vec<_> = contracts
        .iter()
        .filter(|c| c.expiration_date == first && c.contract_type == "call")
        .collect();
    calls.sort_by(|a, b| a.strike_price.partial_cmp(&b.strike_price).unwrap());
    let mid = calls[calls.len() / 2];
    println!(
        "sample: {} K={} exp={}",
        mid.ticker, mid.strike_price, mid.expiration_date
    );
    let bars = client
        .get_aggregates(
            &mid.ticker,
            Granularity::D,
            today - Duration::days(7),
            today,
        )
        .await?;
    for b in &bars {
        println!(
            "  t={} o={} h={} l={} c={} v={} n={:?}",
            b.t, b.o, b.h, b.l, b.c, b.v, b.n
        );
    }
    if let Some(b) = bars.last() {
        let t = (mid.expiration_date - today).num_days().max(1) as f64 / 365.0;
        // spot unknown here; show IV for a guess 1% below strike to prove the solver runs on vendor prices
        let iv = implied_vol(
            OptionKind::Call,
            b.c,
            mid.strike_price * 0.99,
            mid.strike_price,
            t,
            0.04,
            0.012,
        );
        println!("  IV at spot≈0.99K: {:?}", iv);
    }
    Ok(())
}
