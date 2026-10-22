//! Research only: does a trailing stop or profit floor help a live strategy?
//!
//! Runs the real `run_backtest` for a live strategy over its full stored
//! history, then re-walks every trade bar by bar under each candidate rule.
//! A trail or floor can only exit *earlier* than the strategy's own exit, so
//! the variant trade is the original trade cut short where the rule fires.
//! Re-entries that an earlier exit might have allowed are NOT simulated, so
//! variant trade counts equal the baseline's.
//!
//!   cargo run --release --example trail_test -- <live_strategy_id> [oos_split YYYY-MM-DD]
//!
//! Fills use bid/ask like the backtester: trails are checked against the
//! adverse side's extreme (bid low for longs, ask high for shorts) and fill at
//! the trail price, or the bar open when the bar gaps through it.

use std::str::FromStr;

use chrono::{DateTime, NaiveDate, Utc};
use uuid::Uuid;

use auro::db::repositories::candles as candles_repo;
use auro::engine::indicators::atr;
use auro::engine::strategy::{run_backtest, Strategy};
use auro::engine::types::{Candle, Direction, Granularity, Trade};

const ATR_PERIOD: usize = 14;

#[derive(Clone, Copy)]
enum Rule {
    /// Strategy as-is.
    Baseline,
    /// Trail `k` x ATR(14 at entry) behind the best price, from entry.
    AtrTrail { k: f64 },
    /// Once the trade is `arm` (fraction of entry price) in profit, hold a
    /// stop that locks `keep` of the peak open profit, ratcheting with it.
    /// `keep = 0.0` is a plain move-to-breakeven.
    Floor { arm: f64, keep: f64 },
}

impl Rule {
    fn label(&self) -> String {
        match self {
            Rule::Baseline => "baseline".into(),
            Rule::AtrTrail { k } => format!("atr_trail k={k}"),
            Rule::Floor { arm, keep } => {
                format!("floor arm={:.2}% keep={:.0}%", arm * 100.0, keep * 100.0)
            }
        }
    }
}

struct Outcome {
    entry_time: DateTime<Utc>,
    direction: Direction,
    pnl: f64,
    cut_short: bool,
}

fn signed(direction: Direction, entry: f64, price: f64) -> f64 {
    match direction {
        Direction::Long => (price - entry) / entry,
        Direction::Short => (entry - price) / entry,
    }
}

/// Price `dist` on the adverse side of `anchor`.
fn behind(direction: Direction, anchor: f64, dist: f64) -> f64 {
    match direction {
        Direction::Long => anchor - dist,
        Direction::Short => anchor + dist,
    }
}

fn hit(direction: Direction, trigger: f64, stop: f64) -> bool {
    match direction {
        Direction::Long => trigger <= stop,
        Direction::Short => trigger >= stop,
    }
}

/// Walk one baseline trade under `rule`; returns the variant outcome.
fn rewalk(candles: &[Candle], t: &Trade, rule: Rule) -> Outcome {
    let dir = t.direction;
    let entry_idx = candles
        .iter()
        .position(|c| c.time == t.entry_time)
        .expect("entry bar present");
    let exit_idx = candles
        .iter()
        .position(|c| c.time == t.exit_time)
        .expect("exit bar present");
    let base = Outcome {
        entry_time: t.entry_time,
        direction: dir,
        pnl: t.pnl_percent,
        cut_short: false,
    };

    let atr_at_entry = match rule {
        Rule::AtrTrail { .. } => match atr(
            &candles[entry_idx.saturating_sub(ATR_PERIOD + 1)..=entry_idx],
            ATR_PERIOD,
        ) {
            Some(a) => a,
            None => return base,
        },
        _ => 0.0,
    };

    // Favourable extreme so far, tracked on the fill side we'd exit on.
    let mut best = t.entry_price;
    let mut stop: Option<f64> = None;

    for c in &candles[entry_idx + 1..=exit_idx] {
        // 1. Check the stop against this bar's adverse extreme BEFORE updating
        //    the ratchet with this bar (OANDA would fire on the tick that
        //    crosses; we can't order ticks inside a bar, so be conservative).
        if let Some(s) = stop {
            if hit(dir, c.sl_check_price(dir), s) {
                let open = c.directional_open(dir);
                let fill = if hit(dir, open, s) { open } else { s };
                return Outcome {
                    entry_time: t.entry_time,
                    direction: dir,
                    pnl: signed(dir, t.entry_price, fill),
                    cut_short: true,
                };
            }
        }
        // 2. Ratchet on this bar's favourable extreme.
        let fav = match dir {
            Direction::Long => c.bid.as_ref().map(|b| b.high).unwrap_or(c.mid.high),
            Direction::Short => c.ask.as_ref().map(|a| a.low).unwrap_or(c.mid.low),
        };
        let improved = match dir {
            Direction::Long => fav > best,
            Direction::Short => fav < best,
        };
        if improved {
            best = fav;
        }
        let mfe = signed(dir, t.entry_price, best);
        let candidate = match rule {
            Rule::Baseline => None,
            Rule::AtrTrail { k } => Some(behind(dir, best, k * atr_at_entry)),
            Rule::Floor { arm, keep } => {
                if mfe >= arm {
                    // Lock `keep` of the peak open profit, measured from entry.
                    Some(behind(dir, best, (mfe * (1.0 - keep)) * t.entry_price))
                } else {
                    None
                }
            }
        };
        if let Some(c2) = candidate {
            stop = Some(match (stop, dir) {
                (None, _) => c2,
                (Some(s), Direction::Long) => s.max(c2),
                (Some(s), Direction::Short) => s.min(c2),
            });
        }
    }
    base
}

struct Stats {
    n: usize,
    win_rate: f64,
    mean_bp: f64,
    total_pct: f64,
    sharpe: f64,
    max_dd_pct: f64,
    cut: usize,
}

fn stats(outs: &[&Outcome], years: f64) -> Stats {
    let n = outs.len();
    if n == 0 {
        return Stats {
            n,
            win_rate: 0.0,
            mean_bp: 0.0,
            total_pct: 0.0,
            sharpe: 0.0,
            max_dd_pct: 0.0,
            cut: 0,
        };
    }
    let mean = outs.iter().map(|o| o.pnl).sum::<f64>() / n as f64;
    let var = outs.iter().map(|o| (o.pnl - mean).powi(2)).sum::<f64>() / n as f64;
    let sd = var.sqrt();
    let per_year = n as f64 / years;
    let sharpe = if sd > 0.0 {
        mean / sd * per_year.sqrt()
    } else {
        0.0
    };
    let (mut cum, mut peak, mut dd) = (0.0_f64, 0.0_f64, 0.0_f64);
    for o in outs {
        cum += o.pnl;
        peak = peak.max(cum);
        dd = dd.max(peak - cum);
    }
    Stats {
        n,
        win_rate: outs.iter().filter(|o| o.pnl > 0.0).count() as f64 / n as f64,
        mean_bp: mean * 1e4,
        total_pct: cum * 100.0,
        sharpe,
        max_dd_pct: dd * 100.0,
        cut: outs.iter().filter(|o| o.cut_short).count(),
    }
}

fn print_row(label: &str, s: &Stats) {
    println!(
        "{:<28} {:>5} {:>6.1}% {:>7.2}bp {:>8.1}% {:>6.2} {:>7.1}% {:>5}",
        label,
        s.n,
        s.win_rate * 100.0,
        s.mean_bp,
        s.total_pct,
        s.sharpe,
        s.max_dd_pct,
        s.cut
    );
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    dotenvy::dotenv().ok();
    let args: Vec<String> = std::env::args().collect();
    let id = Uuid::from_str(
        args.get(1)
            .ok_or("usage: trail_test <live_strategy_id> [oos_split]")?,
    )?;
    let split = args
        .get(2)
        .map(|s| NaiveDate::from_str(s))
        .transpose()?
        .unwrap_or(NaiveDate::from_ymd_opt(2024, 10, 17).unwrap())
        .and_hms_opt(0, 0, 0)
        .unwrap()
        .and_utc();

    let pool = sqlx::PgPool::connect(&std::env::var("DATABASE_URL")?).await?;
    let parameters: serde_json::Value =
        sqlx::query_scalar("SELECT parameters FROM live_strategies WHERE id = $1")
            .bind(id)
            .fetch_one(&pool)
            .await?;
    let strategy: Strategy = serde_json::from_value(parameters)?;
    let granularity = Granularity::from_str(strategy.granularity.as_str())?;
    let candles = candles_repo::load_candles(&pool, &strategy.instrument, granularity).await?;
    let first = candles.first().map(|c| c.time).unwrap_or_default();
    let last = candles.last().map(|c| c.time).unwrap_or_default();
    let years = (last - first).num_days() as f64 / 365.25;
    println!(
        "{} {} — {} bars, {:.1} years ({} → {}), OOS from {}",
        strategy.instrument,
        granularity,
        candles.len(),
        years,
        first.date_naive(),
        last.date_naive(),
        split.date_naive()
    );

    let trades = run_backtest(&candles, &strategy);
    println!("baseline trades: {}", trades.len());

    let dense = args.get(3).map(|s| s == "dense").unwrap_or(false);
    let mut rules = vec![Rule::Baseline];
    if dense {
        for arm in [0.003, 0.004, 0.005, 0.006, 0.0075, 0.01] {
            for keep in [0.25, 0.4, 0.5, 0.6, 0.75] {
                rules.push(Rule::Floor { arm, keep });
            }
        }
    } else {
        for k in [1.0, 2.0, 3.0, 4.0, 6.0, 8.0] {
            rules.push(Rule::AtrTrail { k });
        }
        for arm in [0.0025, 0.005, 0.0075, 0.01] {
            for keep in [0.0, 0.5, 0.75] {
                rules.push(Rule::Floor { arm, keep });
            }
        }
    }

    let is_years = (split - first).num_days() as f64 / 365.25;
    let oos_years = (last - split).num_days() as f64 / 365.25;

    println!(
        "\n{:<28} {:>5} {:>7} {:>9} {:>9} {:>6} {:>8} {:>5}",
        "rule", "n", "win", "mean", "total", "sharpe", "maxDD", "cut"
    );
    for rule in &rules {
        let outs: Vec<Outcome> = trades.iter().map(|t| rewalk(&candles, t, *rule)).collect();
        let all: Vec<&Outcome> = outs.iter().collect();
        let is: Vec<&Outcome> = outs.iter().filter(|o| o.entry_time < split).collect();
        let oos: Vec<&Outcome> = outs.iter().filter(|o| o.entry_time >= split).collect();
        print_row(&rule.label(), &stats(&all, years));
        if !dense {
            print_row("   in-sample", &stats(&is, is_years));
        }
        print_row("   out-of-sample", &stats(&oos, oos_years));
    }

    // By direction: baseline vs the floor, all and OOS.
    let pick = Rule::Floor {
        arm: 0.005,
        keep: 0.5,
    };
    println!(
        "\n{:<28} {:>5} {:>7} {:>9} {:>9} {:>6} {:>8} {:>5}",
        "by direction", "n", "win", "mean", "total", "sharpe", "maxDD", "cut"
    );
    for dir in [Direction::Long, Direction::Short] {
        for rule in [Rule::Baseline, pick] {
            let outs: Vec<Outcome> = trades
                .iter()
                .filter(|t| t.direction == dir)
                .map(|t| rewalk(&candles, t, rule))
                .collect();
            let all: Vec<&Outcome> = outs.iter().collect();
            let oos: Vec<&Outcome> = outs.iter().filter(|o| o.entry_time >= split).collect();
            print_row(&format!("{:?} {}", dir, rule.label()), &stats(&all, years));
            print_row("   out-of-sample", &stats(&oos, oos_years));
        }
    }
    // Year-by-year by direction.
    let base: Vec<Outcome> = trades
        .iter()
        .map(|t| rewalk(&candles, t, Rule::Baseline))
        .collect();
    let alt: Vec<Outcome> = trades.iter().map(|t| rewalk(&candles, t, pick)).collect();
    println!("\nyear   long_base  long_floor  short_base  short_floor   (total %)");
    let mut ys: Vec<String> = trades
        .iter()
        .map(|t| t.entry_time.format("%Y").to_string())
        .collect();
    ys.sort();
    ys.dedup();
    for y in ys {
        let f = |v: &Vec<Outcome>, d: Direction| -> f64 {
            v.iter()
                .filter(|o| o.direction == d && o.entry_time.format("%Y").to_string() == y)
                .map(|o| o.pnl)
                .sum::<f64>()
                * 100.0
        };
        println!(
            "{}  {:>9.1}  {:>10.1}  {:>10.1}  {:>11.1}",
            y,
            f(&base, Direction::Long),
            f(&alt, Direction::Long),
            f(&base, Direction::Short),
            f(&alt, Direction::Short)
        );
    }
    // Year-by-year: baseline vs the one floor that looked interesting.
    println!(
        "\nyear   base%   floor%   base_sh floor_sh  (floor = {})",
        pick.label()
    );
    let mut years_seen: Vec<i32> = trades
        .iter()
        .map(|t| t.entry_time.format("%Y").to_string().parse().unwrap())
        .collect();
    years_seen.sort();
    years_seen.dedup();
    for y in years_seen {
        let yb: Vec<&Outcome> = base
            .iter()
            .filter(|o| o.entry_time.format("%Y").to_string() == y.to_string())
            .collect();
        let ya: Vec<&Outcome> = alt
            .iter()
            .filter(|o| o.entry_time.format("%Y").to_string() == y.to_string())
            .collect();
        let (sb, sa) = (stats(&yb, 1.0), stats(&ya, 1.0));
        println!(
            "{}  {:>6.1}  {:>6.1}   {:>6.2}  {:>6.2}",
            y, sb.total_pct, sa.total_pct, sb.sharpe, sa.sharpe
        );
    }
    Ok(())
}
