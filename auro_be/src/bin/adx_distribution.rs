use anyhow::Context;
use auro::config::Config;
use auro::db::create_pool;
use auro::engine::indicators::adx;
use auro::engine::types::{Candle, OHLC};
use chrono::{DateTime, Utc};
use sqlx::PgPool;
use std::collections::BTreeMap;

const ADX_PERIOD: usize = 14;
const WINDOW: usize = 200;
const GRANULARITIES: &[&str] = &["M15", "H1", "H4", "D"];

fn sector(instrument: &str) -> &'static str {
    match instrument {
        "XAU_USD" | "XAG_USD" | "XPT_USD" | "XPD_USD" => "metals",
        "WTICO_USD" | "BCO_USD" | "NATGAS_USD" | "XCU_USD" | "CORN_USD" | "SOYBN_USD"
        | "WHEAT_USD" | "SUGAR_USD" => "commodities",
        "SPX500_USD" | "NAS100_USD" | "US30_USD" | "UK100_GBP" | "DE30_EUR" | "JP225_USD"
        | "AU200_AUD" | "EU50_EUR" | "HK33_HKD" | "CN50_USD" => "indices",
        "EUR_USD" | "GBP_USD" | "USD_JPY" | "USD_CHF" | "AUD_USD" | "USD_CAD" | "NZD_USD" => {
            "fx_majors"
        }
        i if i.starts_with("USB") || i == "BUND_EUR" || i == "UK10YB_GBP" => "bonds",
        i if i.contains('_') => "fx_crosses",
        _ => "unknown",
    }
}

struct Stats {
    count: usize,
    p10: f64,
    p25: f64,
    p50: f64,
    p75: f64,
    p90: f64,
    pct_above_30: f64,
    pct_below_15: f64,
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return f64::NAN;
    }
    let rank = p * (sorted.len() - 1) as f64;
    let lo = rank.floor() as usize;
    let hi = rank.ceil() as usize;
    if lo == hi {
        sorted[lo]
    } else {
        let frac = rank - lo as f64;
        sorted[lo] * (1.0 - frac) + sorted[hi] * frac
    }
}

fn summarize(mut values: Vec<f64>) -> Option<Stats> {
    if values.is_empty() {
        return None;
    }
    let n = values.len();
    let above_30 = values.iter().filter(|v| **v > 30.0).count();
    let below_15 = values.iter().filter(|v| **v < 15.0).count();
    values.sort_by(|a, b| a.partial_cmp(b).unwrap());
    Some(Stats {
        count: n,
        p10: percentile(&values, 0.10),
        p25: percentile(&values, 0.25),
        p50: percentile(&values, 0.50),
        p75: percentile(&values, 0.75),
        p90: percentile(&values, 0.90),
        pct_above_30: above_30 as f64 / n as f64 * 100.0,
        pct_below_15: below_15 as f64 / n as f64 * 100.0,
    })
}

async fn load_candles(
    pool: &PgPool,
    instrument: &str,
    granularity: &str,
) -> anyhow::Result<Vec<Candle>> {
    let rows: Vec<(DateTime<Utc>, f64, f64, f64, f64, i32)> = sqlx::query_as(
        "SELECT timestamp, open, high, low, close, volume FROM candles \
         WHERE instrument = $1 AND granularity = $2 ORDER BY timestamp ASC",
    )
    .bind(instrument)
    .bind(granularity)
    .fetch_all(pool)
    .await
    .with_context(|| format!("failed to load candles for {} {}", instrument, granularity))?;

    Ok(rows
        .into_iter()
        .map(|(time, open, high, low, close, volume)| Candle {
            time,
            mid: OHLC {
                open,
                high,
                low,
                close,
            },
            volume,
            bid: None,
            ask: None,
        })
        .collect())
}

fn rolling_adx(candles: &[Candle]) -> Vec<f64> {
    if candles.len() < WINDOW {
        return Vec::new();
    }
    let mut out = Vec::with_capacity(candles.len() - WINDOW + 1);
    for i in WINDOW..=candles.len() {
        if let Some(v) = adx(&candles[i - WINDOW..i], ADX_PERIOD) {
            if v.is_finite() {
                out.push(v);
            }
        }
    }
    out
}

fn print_instrument_table(granularity: &str, rows: &BTreeMap<String, Stats>) {
    println!("\n## {} — per instrument\n", granularity);
    println!("| Sector | Instrument | N | p10 | p25 | p50 | p75 | p90 | %>30 | %<15 |");
    println!("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|");

    let mut by_sector: BTreeMap<&str, Vec<(&String, &Stats)>> = BTreeMap::new();
    for (inst, stats) in rows {
        by_sector
            .entry(sector(inst))
            .or_default()
            .push((inst, stats));
    }

    for (sec, mut entries) in by_sector {
        entries.sort_by_key(|(i, _)| i.as_str());
        for (inst, s) in entries {
            println!(
                "| {} | {} | {} | {:.1} | {:.1} | {:.1} | {:.1} | {:.1} | {:.1}% | {:.1}% |",
                sec,
                inst,
                s.count,
                s.p10,
                s.p25,
                s.p50,
                s.p75,
                s.p90,
                s.pct_above_30,
                s.pct_below_15
            );
        }
    }
}

fn print_sector_table(granularity: &str, sector_values: &BTreeMap<&'static str, Vec<f64>>) {
    println!("\n## {} — per sector (pooled)\n", granularity);
    println!("| Sector | N | p10 | p25 | p50 | p75 | p90 | %>30 | %<15 |");
    println!("|---|---:|---:|---:|---:|---:|---:|---:|---:|");

    for (sec, vals) in sector_values {
        if let Some(s) = summarize(vals.clone()) {
            println!(
                "| {} | {} | {:.1} | {:.1} | {:.1} | {:.1} | {:.1} | {:.1}% | {:.1}% |",
                sec, s.count, s.p10, s.p25, s.p50, s.p75, s.p90, s.pct_above_30, s.pct_below_15
            );
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    let config = Config::from_env().context("failed to load env config")?;
    let pool = create_pool(&config.database_url)
        .await
        .context("failed to connect db")?;

    println!("# ADX(14) distribution over {} candles", WINDOW);
    println!(
        "\nRolling ADX computed at each bar over a {}-bar window (matches live buffer size).\n\
         Global thresholds in RulesEngine: trending if ADX > 30, choppy if ADX < 15.\n\
         `%>30` and `%<15` columns show how often each instrument actually trips those gates.",
        WINDOW
    );

    for gran in GRANULARITIES {
        let instruments: Vec<String> = sqlx::query_scalar(
            "SELECT DISTINCT instrument FROM candles WHERE granularity = $1 ORDER BY instrument",
        )
        .bind(gran)
        .fetch_all(&pool)
        .await
        .with_context(|| format!("failed to list instruments for {}", gran))?;

        if instruments.is_empty() {
            println!("\n## {} — no data\n", gran);
            continue;
        }

        eprintln!("[{}] processing {} instruments…", gran, instruments.len());

        let mut per_instrument: BTreeMap<String, Stats> = BTreeMap::new();
        let mut sector_pool: BTreeMap<&'static str, Vec<f64>> = BTreeMap::new();

        for inst in &instruments {
            let candles = load_candles(&pool, inst, gran).await?;
            let vals = rolling_adx(&candles);
            if let Some(stats) = summarize(vals.clone()) {
                sector_pool.entry(sector(inst)).or_default().extend(vals);
                per_instrument.insert(inst.clone(), stats);
            }
        }

        print_instrument_table(gran, &per_instrument);
        print_sector_table(gran, &sector_pool);
    }

    Ok(())
}
