/// Auro Backtest Runner CLI
///
/// A standalone CLI that drives grid search backtests via the Auro API.
/// Uses tokio for proper async parallelism — no shell scripting needed.
///
/// Add to Cargo.toml:
/// ```toml
/// [[bin]]
/// name = "run_backtests"
/// path = "src/bin/run_backtests.rs"
/// ```
///
/// Usage:
///   cargo run --bin run_backtests -- [options]
///
/// Options:
///   -s, --strategy <mean_reversion|trend_following|both>  (default: both)
///   -p, --parallel <N>                                    (default: 2)
///   -i, --instrument <INSTRUMENT>                         (single instrument)
///   -c, --clear                                           (clear old results first)
///
/// Examples:
///   cargo run --bin run_backtests
///   cargo run --bin run_backtests -- -s trend_following -p 4
///   cargo run --bin run_backtests -- -i EUR_USD -s both
///   cargo run --bin run_backtests -- -p 3 -c
use std::time::Instant;
use tokio::sync::Semaphore;
use std::sync::Arc;

const BASE_URL: &str = "http://127.0.0.1:3000/api";
const TIMEFRAME: &str = "H1";

const INSTRUMENTS: &[&str] = &[
    "AU200_AUD", "AUD_CAD", "AUD_JPY", "AUD_NZD", "AUD_USD",
    "BCO_USD", "CAD_CHF", "CAD_JPY", "CHF_JPY", "CORN_USD",
    "DE30_EUR", "EU50_EUR", "EUR_AUD", "EUR_CAD", "EUR_CHF",
    "EUR_GBP", "EUR_JPY", "EUR_USD", "GBP_AUD", "GBP_CAD",
    "GBP_JPY", "GBP_USD", "JP225_USD", "NAS100_USD", "NATGAS_USD",
    "NZD_CAD", "NZD_JPY", "NZD_USD", "SOYBN_USD", "SPX500_USD",
    "SUGAR_USD", "UK100_GBP", "US30_USD", "USD_CAD", "USD_JPY",
    "WHEAT_USD", "WTICO_USD", "XAG_USD", "XAU_USD", "XCU_USD",
    "XPD_USD", "XPT_USD",
];

#[derive(Debug, serde::Deserialize)]
struct GridResponse {
    strategy: Option<String>,
    instrument: Option<String>,
    error: Option<String>,
    results: Option<ResultCounts>,
    timing: Option<Timing>,
}

#[derive(Debug, serde::Deserialize)]
struct ResultCounts {
    valid: u32,
    verify: u32,
    failed: u32,
}

#[derive(Debug, serde::Deserialize)]
struct Timing {
    grid_seconds: f64,
    store_seconds: f64,
    total_seconds: f64,
}

struct Args {
    strategy: String,
    parallel: usize,
    instrument: Option<String>,
    clear: bool,
}

fn parse_args() -> Args {
    let mut args = Args {
        strategy: "both".into(),
        parallel: 2,
        instrument: None,
        clear: false,
    };

    let raw: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < raw.len() {
        match raw[i].as_str() {
            "-s" | "--strategy" => {
                i += 1;
                args.strategy = raw[i].clone();
            }
            "-p" | "--parallel" => {
                i += 1;
                args.parallel = raw[i].parse().expect("parallel must be a number");
            }
            "-i" | "--instrument" => {
                i += 1;
                args.instrument = Some(raw[i].clone());
            }
            "-c" | "--clear" => {
                args.clear = true;
            }
            "-h" | "--help" => {
                println!("Usage: run_backtests [options]");
                println!();
                println!("Options:");
                println!("  -s, --strategy <mean_reversion|trend_following|both>  (default: both)");
                println!("  -p, --parallel <N>                                    (default: 2)");
                println!("  -i, --instrument <INSTRUMENT>                         (single instrument)");
                println!("  -c, --clear                                           (clear old results first)");
                std::process::exit(0);
            }
            other => {
                eprintln!("Unknown option: {}", other);
                std::process::exit(1);
            }
        }
        i += 1;
    }

    // Validate strategy
    if !["mean_reversion", "trend_following", "both"].contains(&args.strategy.as_str()) {
        eprintln!("Invalid strategy: {}. Must be mean_reversion, trend_following, or both.", args.strategy);
        std::process::exit(1);
    }

    args
}

#[tokio::main]
async fn main() {
    let args = parse_args();
    let client = reqwest::Client::new();

    // Build instrument list
    let instruments: Vec<&str> = if let Some(ref inst) = args.instrument {
        vec![Box::leak(inst.clone().into_boxed_str()) as &str]
    } else {
        INSTRUMENTS.to_vec()
    };

    // Build strategy list
    let strategies: Vec<&str> = match args.strategy.as_str() {
        "both" => vec!["mean_reversion", "trend_following"],
        s => vec![Box::leak(s.to_string().into_boxed_str()) as &str],
    };

    // Build job list
    let mut jobs: Vec<(String, String, usize)> = Vec::new();
    let mut index = 0;
    for strategy in &strategies {
        for instrument in &instruments {
            index += 1;
            jobs.push((instrument.to_string(), strategy.to_string(), index));
        }
    }

    let total = jobs.len();

    println!("==============================================");
    println!("  Auro Grid Search");
    println!("==============================================");
    println!("  Strategies:  {}", args.strategy);
    println!("  Instruments: {}", instruments.len());
    println!("  Total jobs:  {}", total);
    println!("  Parallel:    {}", args.parallel);
    println!("  Timeframe:   {}", TIMEFRAME);
    println!("  Clear first: {}", args.clear);
    println!("==============================================");

    // Clear old results if requested
    if args.clear {
        println!("\nClearing old backtest results...");
        match client.delete(&format!("{}/backtest/results", BASE_URL)).send().await {
            Ok(resp) if resp.status().is_success() => println!("  Cleared."),
            _ => {
                println!("  API delete not available. Clear manually:");
                println!("    docker exec amplyiq-postgres psql -U postgres -d auro -c 'DELETE FROM backtest_trades; DELETE FROM backtest_runs;'");
            }
        }
        println!();
    }

    let start_all = Instant::now();
    let semaphore = Arc::new(Semaphore::new(args.parallel));
    let client = Arc::new(client);

    let mut handles = Vec::new();

    for (instrument, strategy, idx) in jobs {
        let sem = semaphore.clone();
        let client = client.clone();

        let handle = tokio::spawn(async move {
            let _permit = sem.acquire().await.unwrap();

            let job_start = Instant::now();
            let strat_short = if strategy == "trend_following" { "TF" } else { "MR" };

            let url = format!(
                "{}/backtest/run?instrument={}&timeframe={}&strategy={}",
                BASE_URL, instrument, TIMEFRAME, strategy
            );

            let result = match client.post(&url).send().await {
                Ok(resp) => resp.json::<GridResponse>().await.ok(),
                Err(e) => {
                    println!(
                        "[{}/{}] {}  {:<12} — ERROR: {}",
                        idx, total, strat_short, instrument, e
                    );
                    return;
                }
            };

            let elapsed = job_start.elapsed().as_secs();

            match result {
                Some(resp) if resp.error.is_some() => {
                    println!(
                        "[{}/{}] {}  {:<12} — SKIP: {}",
                        idx, total, strat_short, instrument,
                        resp.error.unwrap()
                    );
                }
                Some(resp) => {
                    let counts = resp.results.unwrap_or(ResultCounts { valid: 0, verify: 0, failed: 0 });
                    let timing = resp.timing.as_ref();

                    println!(
                        "[{}/{}] {}  {:<12} — valid:{:<3} verify:{:<3} failed:{:<4} | grid:{:.0}s store:{:.0}s total:{}s",
                        idx, total, strat_short, instrument,
                        counts.valid, counts.verify, counts.failed,
                        timing.map_or(0.0, |t| t.grid_seconds),
                        timing.map_or(0.0, |t| t.store_seconds),
                        elapsed,
                    );
                }
                None => {
                    println!(
                        "[{}/{}] {}  {:<12} — ERROR: failed to parse response",
                        idx, total, strat_short, instrument
                    );
                }
            }
        });

        handles.push(handle);
    }

    // Wait for all tasks to complete
    for handle in handles {
        let _ = handle.await;
    }

    let total_elapsed = start_all.elapsed().as_secs();

    println!();
    println!("==============================================");
    println!("  Complete");
    println!("==============================================");
    println!("  Total time: {}s ({}m {}s)", total_elapsed, total_elapsed / 60, total_elapsed % 60);
    if total > 0 {
        println!("  Avg per job: {}s", total_elapsed / total as u64);
    }
    println!("==============================================");
}