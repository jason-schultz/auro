//! Research only: round 4 volatility-managed index exposure (Moreira & Muir
//! 2017, capped at no leverage), judged against the criteria fixed beforehand
//! in research/round4_preregistration.md.
//!
//! At each month-end close, exposure for the next month is
//! min(1, 0.16² ÷ that month's realized variance, annualized). The rest sits
//! in cash. Same data, costs and windows as round 3 (`common/index_eval.rs`).
//! Results are printed and written to research/results/round4_vol_managed.json.
//!
//!   cargo run --release --example vol_managed

use std::path::Path;

use chrono::{Datelike, NaiveDate, Utc};
use serde_json::json;

mod common;
#[path = "common/index_eval.rs"]
mod index_eval;
use common::yahoo_closes;
use index_eval::{compound, exposure_returns, from_start, pct, score, ymd, SCARES, TRADING_DAYS};

/// Annual volatility at which the index is held in full: the S&P 500's
/// long-run figure, not fitted.
const TARGET_VOL: f64 = 0.16;

/// Exposure held over each day, set at the previous month-end close from that
/// month's realized variance. Fully invested until the first month-end.
fn exposures(dates: &[NaiveDate], prices: &[f64]) -> Vec<f64> {
    let mut exposure = vec![1.0; dates.len()];
    let mut current = 1.0;
    let mut month: Vec<f64> = Vec::new();
    for i in 0..dates.len() {
        exposure[i] = current;
        if i > 0 {
            month.push(prices[i] / prices[i - 1] - 1.0);
        }
        let month_end = dates
            .get(i + 1)
            .is_none_or(|next| next.month() != dates[i].month());
        if month_end && !month.is_empty() {
            let variance =
                month.iter().map(|r| r * r).sum::<f64>() / month.len() as f64 * TRADING_DAYS;
            current = (TARGET_VOL * TARGET_VOL / variance).min(1.0);
            month.clear();
        }
    }
    exposure
}

/// Average exposure between two dates.
fn mean_exposure(dates: &[NaiveDate], exposure: &[f64], from: NaiveDate, to: NaiveDate) -> f64 {
    let held: Vec<f64> = dates
        .iter()
        .zip(exposure)
        .filter(|(d, _)| **d > from && **d <= to)
        .map(|(_, e)| *e)
        .collect();
    held.iter().sum::<f64>() / held.len().max(1) as f64
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let spx = yahoo_closes("GSPC").await?;
    let tsx = yahoo_closes("GSPTSE").await?;

    let mut results = Vec::new();
    let mut verdict = None;
    for (index_name, closes, dividend, scored) in
        [("S&P 500", &spx, 0.020, true), ("TSX", &tsx, 0.027, false)]
    {
        let (dates, prices) = from_start(closes);
        let exposure = exposures(&dates, &prices);
        let hold = exposure_returns(&prices, dividend, &vec![1.0; prices.len()]);
        let managed = exposure_returns(&prices, dividend, &exposure);
        let card = score(&dates, &hold, &managed);
        let average = exposure.iter().sum::<f64>() / exposure.len() as f64;
        let full = exposure.iter().filter(|e| **e >= 1.0).count() as f64 / exposure.len() as f64;

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
        println!(
            "   average exposure {:.0}%, fully invested {:.0}% of days",
            average * 100.0,
            full * 100.0
        );
        let mut crash_rows = Vec::new();
        for ((label, a, b), (_, hold_r, managed_r)) in index_eval::CRASHES.iter().zip(&card.crashes)
        {
            let held = mean_exposure(&dates, &exposure, ymd(*a), ymd(*b));
            println!(
                "   {label:<10} hold {:>7}  managed {:>7}  (average exposure {:.0}%)",
                pct(*hold_r),
                pct(*managed_r),
                held * 100.0
            );
            crash_rows.push(json!({"window": label, "hold": hold_r, "managed": managed_r, "mean_exposure": held}));
        }
        println!(
            "   whole period: Sharpe hold {:+.2} vs managed {:+.2}; worst drawdown hold {} vs managed {}",
            card.sharpe_hold,
            card.sharpe,
            pct(card.drawdown_hold),
            pct(card.drawdown)
        );
        let mut scare_rows = Vec::new();
        for (label, a, b) in SCARES {
            let (a, b) = (ymd(a), ymd(b));
            let (hold_r, managed_r) = (
                compound(&dates, &hold, a, b),
                compound(&dates, &managed, a, b),
            );
            println!(
                "   scare {label:<17} hold {:>7}  managed {:>7}",
                pct(hold_r),
                pct(managed_r)
            );
            scare_rows.push(json!({"scare": label, "hold": hold_r, "managed": managed_r}));
        }
        if scored {
            verdict = Some((card.avoids_crashes, card.worth_it));
        }
        results.push(json!({
            "index": index_name, "mean_exposure": average, "fully_invested_share": full,
            "crashes": crash_rows, "scares": scare_rows,
            "sharpe_hold": card.sharpe_hold, "sharpe_managed": card.sharpe,
            "max_dd_hold": card.drawdown_hold, "max_dd_managed": card.drawdown,
            "crit1_avoids_crashes": card.avoids_crashes, "crit2_worth_it": card.worth_it,
        }));
    }

    let (crashes, worth_it) = verdict.expect("S&P 500 is scored");
    let pass = crashes && worth_it;
    println!("\n==== Verdict (S&P 500)");
    println!(
        "  1 avoids the crashes   {}",
        if crashes { "PASS" } else { "FAIL" }
    );
    println!(
        "  2 worth it overall     {}",
        if worth_it { "PASS" } else { "FAIL" }
    );
    println!("  overall: {}", if pass { "PASS" } else { "FAIL" });

    let out = json!({
        "run_at": Utc::now().to_rfc3339(),
        "verdict": if pass { "PASS" } else { "FAIL" },
        "results": results,
    });
    let path = Path::new("../research/results/round4_vol_managed.json");
    std::fs::create_dir_all(path.parent().expect("results dir"))?;
    std::fs::write(path, serde_json::to_string_pretty(&out)?)?;
    println!("\nwrote {}", path.display());
    Ok(())
}
