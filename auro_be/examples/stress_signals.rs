//! Research only: round 3 stress signals (credit spread, VIX, real-time Sahm
//! rule, two-of-three), judged against the criteria fixed beforehand in
//! research/round3_preregistration.md.
//!
//! Each signal is read at a day's close and acted on at the next close. De-risk
//! holds the index while the signal is off and sits in cash while it's on;
//! short holds a short only while it's on. Costs: 2 bp per switch and an
//! estimated dividend yield (earned long, paid short); cash earns nothing and
//! CFD financing is left out, both of which favour buy-and-hold.
//!
//! FRED series are cached under target/research_cache/fred. FRED often
//! resets or stalls this client's requests; when it does, fetch the same CSV
//! with `curl --compressed "https://fred.stlouisfed.org/graph/fredgraph.csv?id=<ID>"`
//! into that folder as <ID>.csv. Results are
//! printed and written to research/results/round3_stress_signals.json.
//!
//!   cargo run --release --example stress_signals

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{Datelike, Duration, NaiveDate, Utc};
use serde_json::json;

mod common;
#[path = "common/index_eval.rs"]
mod index_eval;
use common::{mean_std, yahoo_closes};
use index_eval::{compound, exposure_returns, from_start, pct, score, ymd, SCARES};

const CREDIT_WINDOW: usize = 252;
const CREDIT_ON_Z: f64 = 2.0;
const VIX_ON: f64 = 30.0;
const VIX_OFF: f64 = 20.0;
const SAHM_ON: f64 = 0.5;
/// Day of the following month from which a monthly Sahm reading is usable.
const SAHM_RELEASE_DAY: u32 = 10;
/// A FRED series as (date, value), skipping missing ("." ) observations.
async fn fred(id: &str) -> Result<Vec<(NaiveDate, f64)>, Box<dyn std::error::Error>> {
    let cache = Path::new("target/research_cache/fred").join(format!("{id}.csv"));
    let body = match std::fs::read_to_string(&cache) {
        Ok(body) => body,
        Err(_) => {
            // FRED resets HTTP/2 requests that don't ask for compression.
            let body = reqwest::Client::builder()
                .http1_only()
                .timeout(std::time::Duration::from_secs(60))
                .build()?
                .get(format!(
                    "https://fred.stlouisfed.org/graph/fredgraph.csv?id={id}"
                ))
                .header("User-Agent", "Mozilla/5.0")
                .send()
                .await?
                .error_for_status()?
                .text()
                .await?;
            std::fs::create_dir_all(cache.parent().expect("cache dir"))?;
            std::fs::write(&cache, &body)?;
            body
        }
    };
    Ok(body
        .lines()
        .skip(1)
        .filter_map(|line| {
            let (date, value) = line.split_once(',')?;
            Some((
                NaiveDate::parse_from_str(date, "%Y-%m-%d").ok()?,
                value.parse().ok()?,
            ))
        })
        .collect())
}

/// On/off with hysteresis: switch on at `on`, off at `off`, else keep state.
fn latch(prev: bool, on: bool, off: bool) -> bool {
    if on {
        true
    } else if off {
        false
    } else {
        prev
    }
}

/// Credit state after each daily spread observation: on at z ≥ 2 against the
/// trailing 252-day mean and deviation, off once back at or below the mean.
fn credit_states(spread: &[(NaiveDate, f64)]) -> Vec<(NaiveDate, bool)> {
    let mut state = false;
    spread
        .iter()
        .enumerate()
        .filter(|(i, _)| *i >= CREDIT_WINDOW)
        .map(|(i, (date, value))| {
            let window: Vec<f64> = spread[i - CREDIT_WINDOW..i].iter().map(|p| p.1).collect();
            let (mean, sd) = mean_std(&window);
            let z = (value - mean) / sd;
            state = latch(state, z >= CREDIT_ON_Z, *value <= mean);
            (*date, state)
        })
        .collect()
}

/// The latest state stamped strictly before `date` (`lag_days` = 1) or at or
/// before it (0).
fn state_before(states: &[(NaiveDate, bool)], date: NaiveDate, lag_days: i64) -> bool {
    let cutoff = date - Duration::days(lag_days);
    let idx = states.partition_point(|(d, _)| *d <= cutoff);
    idx > 0 && states[idx - 1].1
}

/// Signal states per index date, as known at that day's close.
struct Signals {
    credit: Vec<bool>,
    fear: Vec<bool>,
    recession: Vec<bool>,
    combined: Vec<bool>,
}

fn signals(
    dates: &[NaiveDate],
    credit: &[(NaiveDate, bool)],
    vix: &BTreeMap<NaiveDate, f64>,
    sahm: &[(NaiveDate, f64)],
) -> Signals {
    let credit: Vec<bool> = dates.iter().map(|d| state_before(credit, *d, 1)).collect();

    let mut fear_state = false;
    let fear: Vec<bool> = dates
        .iter()
        .map(|d| {
            if let Some(v) = vix.range(..=*d).next_back().map(|(_, v)| *v) {
                fear_state = latch(fear_state, v > VIX_ON, v < VIX_OFF);
            }
            fear_state
        })
        .collect();

    // Month m's reading is usable from the 10th of month m+1.
    let released: Vec<(NaiveDate, bool)> = sahm
        .iter()
        .filter_map(|(month, value)| {
            let next = month.checked_add_months(chrono::Months::new(1))?;
            Some((next.with_day(SAHM_RELEASE_DAY)?, *value >= SAHM_ON))
        })
        .collect();
    let recession: Vec<bool> = dates
        .iter()
        .map(|d| state_before(&released, *d, 0))
        .collect();

    let combined = (0..dates.len())
        .map(|i| {
            [credit[i], fear[i], recession[i]]
                .iter()
                .filter(|s| **s)
                .count()
                >= 2
        })
        .collect();
    Signals {
        credit,
        fear,
        recession,
        combined,
    }
}

/// First date in [from, to] the signal is on, and the share of days on.
fn signal_in(
    dates: &[NaiveDate],
    on: &[bool],
    from: NaiveDate,
    to: NaiveDate,
) -> (Option<NaiveDate>, f64) {
    let days: Vec<(NaiveDate, bool)> = dates
        .iter()
        .zip(on)
        .filter(|(d, _)| **d >= from && **d <= to)
        .map(|(d, s)| (*d, *s))
        .collect();
    let first = days.iter().find(|(_, s)| *s).map(|(d, _)| *d);
    let share = days.iter().filter(|(_, s)| *s).count() as f64 / days.len().max(1) as f64;
    (first, share)
}

struct Verdict {
    name: &'static str,
    derisk_pass: bool,
    short_pass: bool,
    json: serde_json::Value,
}

fn judge(
    name: &'static str,
    dates: &[NaiveDate],
    prices: &[f64],
    dividend: f64,
    on: &[bool],
    report: bool,
) -> Verdict {
    // The signal at close i−1 sets the position held over day i.
    let held = |when_on: f64, when_off: f64| -> Vec<f64> {
        (0..on.len())
            .map(|i| match i.checked_sub(1).map(|p| on[p]) {
                Some(true) => when_on,
                _ => when_off,
            })
            .collect()
    };
    let hold = exposure_returns(prices, dividend, &held(1.0, 1.0));
    let derisk = exposure_returns(prices, dividend, &held(0.0, 1.0));
    let short = exposure_returns(prices, dividend, &held(-1.0, 0.0));
    let card = score(dates, &hold, &derisk);
    let episodes = on.windows(2).filter(|w| !w[0] && w[1]).count();
    let time_on = on.iter().filter(|o| **o).count() as f64 / on.len() as f64;
    if report {
        println!(
            "\n-- {name}: on {:.0}% of days, {episodes} episodes",
            time_on * 100.0
        );
    }

    let mut crash_rows = Vec::new();
    let mut short_wins = 0;
    for ((label, a, b), (_, hold_r, derisk_r)) in index_eval::CRASHES.iter().zip(&card.crashes) {
        let (a, b) = (ymd(*a), ymd(*b));
        let short_r = compound(dates, &short, a, b);
        let (first_on, share) = signal_in(dates, on, a - Duration::days(180), b);
        short_wins += usize::from(short_r > 0.0);
        if report {
            println!(
                "   {label:<10} hold {:>7}  de-risk {:>7}  short {:>7}  first on {}  ({:.0}% of days from 6 months before)",
                pct(*hold_r),
                pct(*derisk_r),
                pct(short_r),
                first_on.map_or("never".into(), |d| d.to_string()),
                share * 100.0
            );
        }
        crash_rows.push(
            json!({"window": label, "hold": hold_r, "derisk": derisk_r, "short": short_r,
            "first_on": first_on.map(|d| d.to_string())}),
        );
    }

    let short_total = short.iter().fold(1.0, |acc, r| acc * (1.0 + r)) - 1.0;
    if report {
        println!(
            "   whole period: Sharpe hold {:+.2} vs de-risk {:+.2}; worst drawdown hold {} vs de-risk {}; short total {}",
            card.sharpe_hold,
            card.sharpe,
            pct(card.drawdown_hold),
            pct(card.drawdown),
            pct(short_total)
        );
    }

    let mut scare_rows = Vec::new();
    for (label, a, b) in SCARES {
        let (a, b) = (ymd(a), ymd(b));
        let hold = compound(dates, &hold, a, b);
        let (first_on, share) = signal_in(dates, on, a, b);
        if report {
            println!(
                "   scare {label:<17} hold {:>7}  signal {}",
                pct(hold),
                first_on.map_or("quiet".to_string(), |d| format!(
                    "ON from {d} ({:.0}% of days)",
                    share * 100.0
                ))
            );
        }
        scare_rows.push(json!({"scare": label, "hold": hold,
            "first_on": first_on.map(|d| d.to_string()), "share_on": share}));
    }

    Verdict {
        name,
        derisk_pass: card.avoids_crashes && card.worth_it,
        short_pass: short_total > 0.0 && short_wins >= 3,
        json: json!({
            "signal": name, "time_on": time_on, "episodes": episodes,
            "crashes": crash_rows, "scares": scare_rows,
            "sharpe_hold": card.sharpe_hold, "sharpe_derisk": card.sharpe,
            "max_dd_hold": card.drawdown_hold, "max_dd_derisk": card.drawdown,
            "short_total": short_total,
            "crit1_avoids_crashes": card.avoids_crashes, "crit2_worth_it": card.worth_it,
        }),
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let spx = yahoo_closes("GSPC").await?;
    let tsx = yahoo_closes("GSPTSE").await?;
    let vix = yahoo_closes("VIX").await?;
    let spread = fred("BAA10Y").await?;
    let sahm = fred("SAHMREALTIME").await?;
    let credit = credit_states(&spread);

    let mut results = Vec::new();
    let mut verdicts = Vec::new();
    for (index_name, closes, dividend, scored) in
        [("S&P 500", &spx, 0.020, true), ("TSX", &tsx, 0.027, false)]
    {
        let (dates, prices) = from_start(closes);
        let sig = signals(&dates, &credit, &vix, &sahm);
        println!(
            "\n==== {index_name} ({} → {}){}",
            dates[0],
            dates[dates.len() - 1],
            if scored {
                ""
            } else {
                "  [reported, not scored]"
            }
        );
        for (name, on) in [
            ("credit", &sig.credit),
            ("fear (VIX)", &sig.fear),
            ("recession (Sahm)", &sig.recession),
            ("two of three", &sig.combined),
        ] {
            let v = judge(name, &dates, &prices, dividend, on, true);
            if scored {
                verdicts.push((v.name, v.derisk_pass, v.short_pass));
            }
            results.push(json!({"index": index_name, "result": v.json}));
        }
    }

    println!("\n==== Verdict (S&P 500)");
    for (name, derisk, short) in &verdicts {
        println!(
            "  {name:<18} de-risk {}   short {}",
            if *derisk { "PASS" } else { "FAIL" },
            if *short { "allowed" } else { "not allowed" }
        );
    }

    let out = json!({
        "run_at": Utc::now().to_rfc3339(),
        "verdicts": verdicts.iter().map(|(n, d, s)| json!({"signal": n, "derisk_pass": d, "short_allowed": s})).collect::<Vec<_>>(),
        "results": results,
    });
    let path = Path::new("../research/results/round3_stress_signals.json");
    std::fs::create_dir_all(path.parent().expect("results dir"))?;
    std::fs::write(path, serde_json::to_string_pretty(&out)?)?;
    println!("\nwrote {}", path.display());
    Ok(())
}
