//! Research only: is a live strategy's edge uniform, or concentrated in some
//! market condition that was knowable before the entry?
//!
//! Runs the real `run_backtest`, builds NYSE regular-hours daily sessions
//! from the same bars, and buckets every trade by conditions observable at
//! the time of entry: prior 1- and 5-session return, prior-session range vs
//! its 20-session mean, and the opening gap. Prints mean bp/trade, win rate
//! and a t-stat per bucket, for all trades and per direction.
//!
//!   cargo run --release --example edge_audit -- <live_strategy_id>

use std::collections::BTreeMap;
use std::str::FromStr;

use chrono::{NaiveDate, Timelike};
use chrono_tz::America::New_York;
use uuid::Uuid;

use auro::db::repositories::candles as candles_repo;
use auro::engine::strategy::{run_backtest, Strategy};
use auro::engine::types::{Candle, Direction, Granularity, Trade};

struct Session {
    open: f64,
    high: f64,
    low: f64,
    close: f64,
}

/// NYSE regular-hours OHLC per New York date, from M5 bars (timestamps are
/// bar opens).
fn sessions(candles: &[Candle]) -> BTreeMap<NaiveDate, Session> {
    let mut out: BTreeMap<NaiveDate, Session> = BTreeMap::new();
    for c in candles {
        let ny = c.time.with_timezone(&New_York);
        let min = i64::from(ny.hour()) * 60 + i64::from(ny.minute());
        if !(570..960).contains(&min) {
            continue;
        }
        let s = out.entry(ny.date_naive()).or_insert(Session {
            open: c.mid.open,
            high: c.mid.high,
            low: c.mid.low,
            close: c.mid.close,
        });
        s.high = s.high.max(c.mid.high);
        s.low = s.low.min(c.mid.low);
        s.close = c.mid.close;
    }
    out
}

struct Features {
    r1: f64,
    r5: f64,
    range_ratio: f64,
    gap: f64,
}

fn features(days: &[(&NaiveDate, &Session)], idx: usize) -> Option<Features> {
    if idx < 22 {
        return None;
    }
    let s = |k: usize| days[idx - k].1;
    let r1 = s(1).close / s(2).close - 1.0;
    let r5 = s(1).close / s(6).close - 1.0;
    let range = |k: usize| (s(k).high - s(k).low) / s(k).close;
    let mean20 = (2..=21).map(range).sum::<f64>() / 20.0;
    let range_ratio = range(1) / mean20;
    let gap = days[idx].1.open / s(1).close - 1.0;
    Some(Features {
        r1,
        r5,
        range_ratio,
        gap,
    })
}

fn bucket(v: f64, edges: &[f64], labels: &[&str]) -> &'static str {
    let i = edges.iter().position(|e| v < *e).unwrap_or(edges.len());
    // labels are 'static str literals in the caller; map by index
    let _ = labels;
    ["a", "b", "c", "d", "e"][i]
}

struct Cell {
    pnls: Vec<f64>,
}

impl Cell {
    fn line(&self) -> String {
        let n = self.pnls.len();
        if n == 0 {
            return format!("{:>5} {:>8} {:>6} {:>6}", 0, "-", "-", "-");
        }
        let mean = self.pnls.iter().sum::<f64>() / n as f64;
        let sd = (self.pnls.iter().map(|p| (p - mean).powi(2)).sum::<f64>() / n as f64).sqrt();
        let t = if sd > 0.0 {
            mean / sd * (n as f64).sqrt()
        } else {
            0.0
        };
        let win = self.pnls.iter().filter(|p| **p > 0.0).count() as f64 / n as f64;
        format!(
            "{:>5} {:>7.2}bp {:>5.0}% {:>6.2}",
            n,
            mean * 1e4,
            win * 100.0,
            t
        )
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    dotenvy::dotenv().ok();
    let args: Vec<String> = std::env::args().collect();
    let id = Uuid::from_str(args.get(1).ok_or("usage: edge_audit <live_strategy_id>")?)?;
    let pool = sqlx::PgPool::connect(&std::env::var("DATABASE_URL")?).await?;
    let parameters: serde_json::Value =
        sqlx::query_scalar("SELECT parameters FROM live_strategies WHERE id = $1")
            .bind(id)
            .fetch_one(&pool)
            .await?;
    let strategy: Strategy = serde_json::from_value(parameters)?;
    let granularity = Granularity::from_str(strategy.granularity.as_str())?;
    let candles = candles_repo::load_candles(&pool, &strategy.instrument, granularity).await?;
    let trades: Vec<Trade> = run_backtest(&candles, &strategy);
    let sess = sessions(&candles);
    let days: Vec<(&NaiveDate, &Session)> = sess.iter().collect();
    println!("{} trades, {} sessions", trades.len(), days.len());

    // feature name -> (edges, labels)
    let specs: Vec<(&str, Vec<f64>, Vec<&str>)> = vec![
        (
            "prior 5-day return",
            vec![-0.02, 0.0, 0.02],
            vec!["< -2%", "-2..0%", "0..2%", "> 2%"],
        ),
        (
            "prior 1-day return",
            vec![-0.01, 0.0, 0.01],
            vec!["< -1%", "-1..0%", "0..1%", "> 1%"],
        ),
        (
            "prior-day range / 20d mean",
            vec![0.75, 1.25, 2.0],
            vec!["< 0.75", "0.75-1.25", "1.25-2", "> 2"],
        ),
        (
            "opening gap",
            vec![-0.005, 0.0, 0.005],
            vec!["< -0.5%", "-0.5..0%", "0..0.5%", "> 0.5%"],
        ),
    ];

    let mut rows: Vec<(usize, Features, Direction, f64)> = Vec::new();
    let mut skipped = 0;
    for t in &trades {
        let d = t.entry_time.with_timezone(&New_York).date_naive();
        let Some(idx) = days.iter().position(|(k, _)| **k == d) else {
            skipped += 1;
            continue;
        };
        match features(&days, idx) {
            Some(f) => rows.push((idx, f, t.direction, t.pnl_percent)),
            None => skipped += 1,
        }
    }
    println!(
        "{} trades bucketed, {} skipped (no session/warm-up)\n",
        rows.len(),
        skipped
    );

    for (name, edges, labels) in &specs {
        println!("== {} ==", name);
        println!(
            "{:<12} | {:>5} {:>9} {:>6} {:>6} | {:>5} {:>9} {:>6} {:>6} | {:>5} {:>9} {:>6} {:>6}",
            "bucket", "n", "all", "win", "t", "n", "long", "win", "t", "n", "short", "win", "t"
        );
        for (bi, label) in labels.iter().enumerate() {
            let key = ["a", "b", "c", "d", "e"][bi];
            let pick = |r: &(usize, Features, Direction, f64)| -> f64 {
                match *name {
                    "prior 5-day return" => r.1.r5,
                    "prior 1-day return" => r.1.r1,
                    "prior-day range / 20d mean" => r.1.range_ratio,
                    _ => r.1.gap,
                }
            };
            let sel: Vec<&(usize, Features, Direction, f64)> = rows
                .iter()
                .filter(|r| bucket(pick(r), edges, labels) == key)
                .collect();
            let all = Cell {
                pnls: sel.iter().map(|r| r.3).collect(),
            };
            let long = Cell {
                pnls: sel
                    .iter()
                    .filter(|r| r.2 == Direction::Long)
                    .map(|r| r.3)
                    .collect(),
            };
            let short = Cell {
                pnls: sel
                    .iter()
                    .filter(|r| r.2 == Direction::Short)
                    .map(|r| r.3)
                    .collect(),
            };
            println!(
                "{:<12} | {} | {} | {}",
                label,
                all.line(),
                long.line(),
                short.line()
            );
        }
        println!();
    }
    Ok(())
}
