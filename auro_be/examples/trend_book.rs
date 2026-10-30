//! Research only: the round 2 trend book (Hurst, Ooi & Pedersen 2017, "A
//! Century of Evidence on Trend-Following Investing"), judged against the
//! criteria fixed beforehand in research/round2_preregistration.md.
//!
//! Spec: at each month-end close every instrument's position is the average
//! sign of its 1-, 3- and 12-month return (−1, −⅓, +⅓, +1), scaled by the
//! inverse of its ex-ante volatility (EWMA of squared daily returns, centre of
//! mass 60 days), equal-weighted across instruments and held for the month.
//! Results are scaled to 10% annual book volatility; costs and financing are
//! linear in position size, so the scaling is exact.
//!
//! Two books:
//!   * OANDA: every active OANDA instrument, daily bars from the DB, half the
//!     median stored bid/ask spread per unit traded, overnight financing from
//!     the engine's `FinancingModel` (recorded OANDA rates where we have them).
//!   * Long index history (Yahoo daily closes, 1985 on), only to see crisis
//!     behaviour before OANDA data starts. Costs: the matching OANDA index's
//!     spread, the 2.5% index markup, and an estimated dividend yield (longs
//!     earn it, shorts pay it). The cash-rate leg of financing is left out,
//!     which understates shorts in high-rate years (2000, 2007).
//!
//! Results are
//! printed and written to research/results/round2_trend_book.json.
//!
//!   cargo run --release --example trend_book

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::Path;
use std::str::FromStr;

use chrono::{Datelike, Duration, NaiveDate, Utc};
use chrono_tz::America::New_York;
use serde_json::{json, Value};

mod common;
use common::{mean_std, yahoo_closes};

use auro::db::repositories::{candles as candles_repo, financing as financing_repo};
use auro::engine::financing::{apply_costs, FinancingModel};
use auro::engine::strategy::{run_backtest, Strategy};
use auro::engine::types::{Direction, Granularity};

/// EWMA decay for a 60-day centre of mass.
const LAMBDA: f64 = 60.0 / 61.0;
const TRADING_DAYS: f64 = 261.0;
const BOOK_VOL: f64 = 0.10;
/// Daily observations before an instrument may trade (12-month signal plus a
/// settled volatility estimate).
const MIN_HISTORY: usize = 260;
/// Annual volatility each instrument is scaled to before equal weighting.
const INSTRUMENT_VOL: f64 = 0.40;
const INDEX_MARKUP: f64 = 0.025;

type Ymd = (i32, u32, u32);

const CRISES: [(&str, Ymd, Ymd); 4] = [
    ("dot-com 2000-09..2002-10", (2000, 9, 1), (2002, 10, 31)),
    ("housing 2007-10..2009-03", (2007, 10, 1), (2009, 3, 31)),
    ("covid 2020-02..2020-04", (2020, 2, 1), (2020, 4, 30)),
    ("2022 bear 2022-01..2022-10", (2022, 1, 1), (2022, 10, 31)),
];
const CRISIS_YEARS: [i32; 8] = [2000, 2001, 2002, 2007, 2008, 2009, 2020, 2022];
const CALM_YEAR_FLOOR: f64 = -0.03;

/// Yahoo symbol, matching OANDA index (for its spread), dividend yield
/// estimate (0 for the DAX, a total-return index).
const LONG_HISTORY: [(&str, &str, f64); 8] = [
    ("GSPC", "SPX500_USD", 0.020),
    ("NDX", "NAS100_USD", 0.010),
    ("DJI", "US30_USD", 0.022),
    ("GDAXI", "DE30_EUR", 0.0),
    ("STOXX50E", "EU50_EUR", 0.030),
    ("FTSE", "UK100_GBP", 0.035),
    ("N225", "JP225_USD", 0.015),
    ("AXJO", "AU200_AUD", 0.040),
];

#[derive(Clone, Copy)]
enum Carry {
    Oanda,
    Flat {
        dividend: f64,
    },
    /// No financing at all: the gross diagnostic.
    Free,
}

struct Market {
    name: String,
    class: String,
    closes: BTreeMap<NaiveDate, f64>,
    half_spread: f64,
    carry: Carry,
}

struct Book {
    dates: Vec<NaiveDate>,
    /// Net daily return, unscaled.
    returns: Vec<f64>,
    /// Net daily contribution per instrument, unscaled.
    contributions: HashMap<String, Vec<(NaiveDate, f64)>>,
}

fn sign(x: f64) -> f64 {
    if x > 0.0 {
        1.0
    } else if x < 0.0 {
        -1.0
    } else {
        0.0
    }
}

fn simulate(markets: &[&Market], financing: &FinancingModel) -> Book {
    let calendar: Vec<NaiveDate> = markets
        .iter()
        .flat_map(|m| m.closes.keys().copied())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();

    struct State {
        last: Option<f64>,
        var: f64,
        obs: usize,
        month_ends: Vec<f64>,
        weight: f64,
    }
    let mut states: Vec<State> = markets
        .iter()
        .map(|_| State {
            last: None,
            var: 0.0,
            obs: 0,
            month_ends: Vec::new(),
            weight: 0.0,
        })
        .collect();

    let mut book = Book {
        dates: Vec::with_capacity(calendar.len()),
        returns: Vec::with_capacity(calendar.len()),
        contributions: HashMap::new(),
    };
    let mut held = 0usize;

    for (idx, &date) in calendar.iter().enumerate() {
        let gap_days = idx
            .checked_sub(1)
            .map_or(1, |p| (date - calendar[p]).num_days());
        let mut day = 0.0;
        let mut contributions = vec![0.0; markets.len()];

        for (i, (market, state)) in markets.iter().zip(states.iter_mut()).enumerate() {
            let price = market.closes.get(&date).copied();
            let r = match (price, state.last) {
                (Some(p), Some(prev)) => p / prev - 1.0,
                _ => 0.0,
            };
            if state.weight != 0.0 {
                let direction = if state.weight > 0.0 {
                    Direction::Long
                } else {
                    Direction::Short
                };
                let rate = match market.carry {
                    Carry::Oanda => financing.annual_rate(&market.name, direction, date),
                    Carry::Flat { dividend } => {
                        let earned = match direction {
                            Direction::Long => dividend,
                            Direction::Short => -dividend,
                        };
                        earned - INDEX_MARKUP
                    }
                    Carry::Free => 0.0,
                };
                let c = (state.weight * r + state.weight.abs() * rate * gap_days as f64 / 365.0)
                    / held as f64;
                contributions[i] = c;
                day += c;
            }
            if let (Some(p), Some(_)) = (price, state.last) {
                state.var = if state.obs == 0 {
                    r * r
                } else {
                    LAMBDA * state.var + (1.0 - LAMBDA) * r * r
                };
                state.obs += 1;
                state.last = Some(p);
            } else if let Some(p) = price {
                state.last = Some(p);
            }
        }

        let month_end = calendar
            .get(idx + 1)
            .is_none_or(|next| next.month() != date.month());
        if month_end {
            let new_weights: Vec<f64> = states
                .iter_mut()
                .map(|state| {
                    let Some(p) = state.last else { return 0.0 };
                    state.month_ends.push(p);
                    let me = &state.month_ends;
                    if state.obs < MIN_HISTORY || me.len() < 13 || state.var <= 0.0 {
                        return 0.0;
                    }
                    let back = |k: usize| p / me[me.len() - 1 - k] - 1.0;
                    let signal = (sign(back(1)) + sign(back(3)) + sign(back(12))) / 3.0;
                    let vol = (state.var * TRADING_DAYS).sqrt();
                    signal * INSTRUMENT_VOL / vol
                })
                .collect();
            let new_held = new_weights.iter().filter(|w| **w != 0.0).count();
            if new_held > 0 {
                for (i, (market, state)) in markets.iter().zip(states.iter_mut()).enumerate() {
                    let cost = (new_weights[i] - state.weight).abs() * market.half_spread
                        / new_held as f64;
                    contributions[i] -= cost;
                    day -= cost;
                    state.weight = new_weights[i];
                }
            } else {
                for state in states.iter_mut() {
                    state.weight = 0.0;
                }
            }
            held = new_held;
        }

        book.dates.push(date);
        book.returns.push(day);
        for (market, c) in markets.iter().zip(contributions) {
            if c != 0.0 {
                book.contributions
                    .entry(market.name.clone())
                    .or_default()
                    .push((date, c));
            }
        }
    }

    // Drop the warm-up: nothing is held until the first instrument qualifies.
    let first = book.returns.iter().position(|r| *r != 0.0).unwrap_or(0);
    book.dates.drain(..first);
    book.returns.drain(..first);
    book
}

/// Leverage that puts the book at 10% annual volatility.
fn scale(book: &Book) -> f64 {
    let (_, sd) = mean_std(&book.returns);
    BOOK_VOL / (sd * TRADING_DAYS.sqrt())
}

fn compound(book: &Book, k: f64, from: NaiveDate, to: NaiveDate) -> Option<f64> {
    let mut covered = false;
    let total = book
        .dates
        .iter()
        .zip(&book.returns)
        .filter(|(d, _)| **d >= from && **d <= to)
        .fold(1.0, |acc, (_, r)| {
            covered = true;
            acc * (1.0 + k * r)
        });
    covered.then_some(total - 1.0)
}

fn ymd((y, m, d): Ymd) -> NaiveDate {
    NaiveDate::from_ymd_opt(y, m, d).expect("valid date")
}

/// Calendar-year returns for years the book covers in full.
fn full_years(book: &Book, k: f64) -> BTreeMap<i32, f64> {
    let (Some(first), Some(last)) = (book.dates.first(), book.dates.last()) else {
        return BTreeMap::new();
    };
    (first.year()..=last.year())
        .filter(|y| *first <= ymd((*y, 1, 10)) && *last >= ymd((*y, 12, 20)))
        .filter_map(|y| compound(book, k, ymd((y, 1, 1)), ymd((y, 12, 31))).map(|r| (y, r)))
        .collect()
}

fn monthly(book: &Book, k: f64) -> BTreeMap<(i32, u32), f64> {
    let mut out: BTreeMap<(i32, u32), f64> = BTreeMap::new();
    for (d, r) in book.dates.iter().zip(&book.returns) {
        let m = out.entry((d.year(), d.month())).or_insert(1.0);
        *m *= 1.0 + k * r;
    }
    out.into_iter().map(|(key, v)| (key, v - 1.0)).collect()
}

fn correlation(pairs: &[(f64, f64)]) -> Option<f64> {
    if pairs.len() < 3 {
        return None;
    }
    let xs: Vec<f64> = pairs.iter().map(|p| p.0).collect();
    let ys: Vec<f64> = pairs.iter().map(|p| p.1).collect();
    let (mx, sx) = mean_std(&xs);
    let (my, sy) = mean_std(&ys);
    let cov =
        pairs.iter().map(|(x, y)| (x - mx) * (y - my)).sum::<f64>() / (pairs.len() as f64 - 1.0);
    Some(cov / (sx * sy))
}

/// The three instruments with the largest net contribution, over the given
/// windows (or the whole book when `windows` is empty).
fn top_contributors(book: &Book, windows: &[(NaiveDate, NaiveDate)]) -> Vec<String> {
    let mut totals: Vec<(String, f64)> = book
        .contributions
        .iter()
        .map(|(name, series)| {
            let total = series
                .iter()
                .filter(|(d, _)| {
                    windows.is_empty() || windows.iter().any(|(a, b)| d >= a && d <= b)
                })
                .map(|(_, c)| c)
                .sum::<f64>();
            (name.clone(), total)
        })
        .collect();
    totals.sort_by(|a, b| b.1.total_cmp(&a.1));
    totals.into_iter().take(3).map(|(n, _)| n).collect()
}

fn crisis_windows() -> Vec<(&'static str, NaiveDate, NaiveDate)> {
    CRISES
        .iter()
        .map(|(name, a, b)| (*name, ymd(*a), ymd(*b)))
        .collect()
}

/// Criterion 1: positive in every crisis window.
fn crisis_returns(book: &Book) -> Vec<(&'static str, Option<f64>)> {
    let k = scale(book);
    crisis_windows()
        .into_iter()
        .map(|(name, a, b)| (name, compound(book, k, a, b)))
        .collect()
}

/// Criterion 2: mean return over full calm (non-crisis) years.
fn calm_mean(book: &Book) -> (f64, BTreeMap<i32, f64>) {
    let years = full_years(book, scale(book));
    let calm: Vec<f64> = years
        .iter()
        .filter(|(y, _)| !CRISIS_YEARS.contains(y))
        .map(|(_, r)| *r)
        .collect();
    (calm.iter().sum::<f64>() / calm.len() as f64, years)
}

/// Criterion 3: correlation with the live long sleeves over their losing
/// months, plus the book's mean return in those months.
fn hedge(book: &Book, sleeves: &BTreeMap<(i32, u32), f64>) -> (Option<f64>, f64, usize) {
    let months = monthly(book, scale(book));
    let pairs: Vec<(f64, f64)> = sleeves
        .iter()
        .filter(|(_, s)| **s < 0.0)
        .filter_map(|(m, s)| months.get(m).map(|b| (*b, *s)))
        .collect();
    let mean = pairs.iter().map(|p| p.0).sum::<f64>() / pairs.len().max(1) as f64;
    (correlation(&pairs), mean, pairs.len())
}

fn sharpe(book: &Book) -> f64 {
    let (m, sd) = mean_std(&book.returns);
    m / sd * TRADING_DAYS.sqrt()
}

fn pct(x: f64) -> String {
    format!("{:+.1}%", x * 100.0)
}

fn median(mut xs: Vec<f64>) -> f64 {
    if xs.is_empty() {
        return 0.0;
    }
    xs.sort_by(f64::total_cmp);
    xs[xs.len() / 2]
}

async fn oanda_market(
    pool: &sqlx::PgPool,
    name: &str,
    class: &str,
) -> Result<Market, Box<dyn std::error::Error>> {
    let candles = candles_repo::load_candles(pool, name, Granularity::D).await?;
    let spreads: Vec<f64> = candles
        .iter()
        .filter_map(|c| Some((c.ask.as_ref()?.close - c.bid.as_ref()?.close) / c.mid.close))
        .filter(|s| *s > 0.0)
        .collect();
    let closes = candles
        .iter()
        .map(|c| {
            // Bars are stamped at their open; date them by their close in New York.
            let close = (c.time + Duration::days(1)).with_timezone(&New_York);
            (close.date_naive(), c.mid.close)
        })
        .collect();
    Ok(Market {
        name: name.to_string(),
        class: class.to_string(),
        closes,
        half_spread: median(spreads) / 2.0,
        carry: Carry::Oanda,
    })
}

/// Monthly return of the live long sleeves (equal weight, trades booked in the
/// month they exit), from their own backtests with financing.
async fn live_sleeves(
    pool: &sqlx::PgPool,
    financing: &FinancingModel,
) -> Result<(Vec<String>, BTreeMap<(i32, u32), f64>), Box<dyn std::error::Error>> {
    let rows: Vec<(String, Value)> = sqlx::query_as(
        "SELECT instrument, parameters FROM live_strategies WHERE enabled ORDER BY instrument, granularity",
    )
    .fetch_all(pool)
    .await?;
    let mut names = Vec::new();
    let mut months: BTreeMap<(i32, u32), f64> = BTreeMap::new();
    let n = rows.len() as f64;
    for (instrument, parameters) in rows {
        let strategy: Strategy = serde_json::from_value(parameters)?;
        let granularity = Granularity::from_str(strategy.granularity.as_str())?;
        let candles = candles_repo::load_candles(pool, &instrument, granularity).await?;
        let mut trades = run_backtest(&candles, &strategy);
        apply_costs(&mut trades, &instrument, financing);
        names.push(format!(
            "{instrument} {granularity} ({} trades)",
            trades.len()
        ));
        for t in trades {
            let d = t.exit_time.date_naive();
            *months.entry((d.year(), d.month())).or_default() += t.pnl_percent / n;
        }
    }
    Ok((names, months))
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    dotenvy::dotenv().ok();
    let pool = sqlx::PgPool::connect(&std::env::var("DATABASE_URL")?).await?;
    let financing = financing_repo::load_model(&pool).await?;

    let listings: Vec<(String, String)> = sqlx::query_as(
        "SELECT oanda_symbol, asset_class FROM instruments \
         WHERE active AND oanda_symbol IS NOT NULL ORDER BY oanda_symbol",
    )
    .fetch_all(&pool)
    .await?;
    let mut oanda = Vec::new();
    for (name, class) in &listings {
        oanda.push(oanda_market(&pool, name, class).await?);
    }

    let mut indices = Vec::new();
    for (symbol, oanda_name, dividend) in LONG_HISTORY {
        let half_spread = oanda
            .iter()
            .find(|m| m.name == oanda_name)
            .map_or(0.0, |m| m.half_spread);
        indices.push(Market {
            name: symbol.to_string(),
            class: "index".to_string(),
            closes: yahoo_closes(symbol).await?,
            half_spread,
            carry: Carry::Flat { dividend },
        });
    }
    let (sleeve_names, sleeves) = live_sleeves(&pool, &financing).await?;

    let oanda_refs: Vec<&Market> = oanda.iter().collect();
    let index_refs: Vec<&Market> = indices.iter().collect();
    let oanda_book = simulate(&oanda_refs, &financing);
    let index_book = simulate(&index_refs, &financing);

    println!("== Data");
    println!(
        "OANDA book: {} instruments, {} → {}",
        oanda.len(),
        oanda_book.dates[0],
        oanda_book.dates[oanda_book.dates.len() - 1]
    );
    for m in &indices {
        println!(
            "  {} from {}",
            m.name,
            m.closes.keys().next().map_or("-".into(), |d| d.to_string())
        );
    }
    println!(
        "Long index book: {} → {}",
        index_book.dates[0],
        index_book.dates[index_book.dates.len() - 1]
    );
    println!("Live sleeves: {}", sleeve_names.join(", "));

    // Criterion 1 on the long index history; OANDA shown for reference.
    let c1 = crisis_returns(&index_book);
    let c1_oanda = crisis_returns(&oanda_book);
    println!("\n== 1. Pays in crashes (long index history, 10% vol)");
    for ((name, r), (_, ro)) in c1.iter().zip(&c1_oanda) {
        println!(
            "  {name:<28} index {:>8}   OANDA book {:>8}",
            r.map_or("n/a".into(), pct),
            ro.map_or("n/a".into(), pct)
        );
    }
    let pass1 = |c: &[(&str, Option<f64>)]| c.iter().all(|(_, r)| r.is_some_and(|r| r > 0.0));

    // Criterion 2 on the OANDA book.
    let (calm, years) = calm_mean(&oanda_book);
    println!("\n== 2. Cheap in calm years (OANDA book, 10% vol)");
    for (y, r) in &years {
        let tag = if CRISIS_YEARS.contains(y) {
            " (crisis)"
        } else {
            ""
        };
        println!("  {y}  {:>8}{tag}", pct(*r));
    }
    println!(
        "  calm-year mean {} (floor {})",
        pct(calm),
        pct(CALM_YEAR_FLOOR)
    );
    let (idx_calm, _) = calm_mean(&index_book);
    println!("  (long index book calm-year mean {})", pct(idx_calm));

    // Criterion 3.
    let (corr, mean_in_losses, n_losses) = hedge(&oanda_book, &sleeves);
    println!("\n== 3. Hedges the live long sleeves (their {n_losses} losing months)");
    println!(
        "  correlation {}   book mean in those months {}",
        corr.map_or("n/a".into(), |c| format!("{c:+.2}")),
        pct(mean_in_losses)
    );
    let pass3 = |c: Option<f64>| c.is_some_and(|c| c <= 0.0);

    // Criterion 4: drop the top three contributors and re-check.
    let windows: Vec<(NaiveDate, NaiveDate)> = crisis_windows()
        .into_iter()
        .map(|(_, a, b)| (a, b))
        .collect();
    let drop_idx = top_contributors(&index_book, &windows);
    let drop_oanda = top_contributors(&oanda_book, &[]);
    let index_rest: Vec<&Market> = indices
        .iter()
        .filter(|m| !drop_idx.contains(&m.name))
        .collect();
    let oanda_rest: Vec<&Market> = oanda
        .iter()
        .filter(|m| !drop_oanda.contains(&m.name))
        .collect();
    let index_book4 = simulate(&index_rest, &financing);
    let oanda_book4 = simulate(&oanda_rest, &financing);
    let c1_4 = crisis_returns(&index_book4);
    let (calm4, _) = calm_mean(&oanda_book4);
    let (corr4, _, _) = hedge(&oanda_book4, &sleeves);
    println!("\n== 4. Without the top three contributors");
    println!("  index book drops {:?}", drop_idx);
    for (name, r) in &c1_4 {
        println!("    {name:<28} {:>8}", r.map_or("n/a".into(), pct));
    }
    println!("  OANDA book drops {:?}", drop_oanda);
    println!(
        "    calm-year mean {}   losing-month correlation {}",
        pct(calm4),
        corr4.map_or("n/a".into(), |c| format!("{c:+.2}"))
    );

    let pass = [
        pass1(&c1),
        calm >= CALM_YEAR_FLOOR,
        pass3(corr),
        pass1(&c1_4) && calm4 >= CALM_YEAR_FLOOR && pass3(corr4),
    ];

    // Context, not criteria: by class, and the whole-sample Sharpe.
    println!("\n== Context");
    println!(
        "  Sharpe: OANDA book {:+.2}, long index book {:+.2}",
        sharpe(&oanda_book),
        sharpe(&index_book)
    );
    // Gross: the same books with no spread and no financing, to show how much
    // of the result is cost.
    let gross = |markets: &[Market]| {
        let free: Vec<Market> = markets
            .iter()
            .map(|m| Market {
                name: m.name.clone(),
                class: m.class.clone(),
                closes: m.closes.clone(),
                half_spread: 0.0,
                carry: Carry::Free,
            })
            .collect();
        sharpe(&simulate(&free.iter().collect::<Vec<_>>(), &financing))
    };
    let gross_oanda = gross(&oanda);
    let gross_index = gross(&indices);
    println!("  gross Sharpe (no costs): OANDA book {gross_oanda:+.2}, long index book {gross_index:+.2}");
    let k = scale(&oanda_book);
    let mut by_class: BTreeMap<String, f64> = BTreeMap::new();
    for m in &oanda {
        let total: f64 = oanda_book
            .contributions
            .get(&m.name)
            .map_or(0.0, |s| s.iter().map(|(_, c)| c).sum());
        *by_class.entry(m.class.clone()).or_default() += total * k;
    }
    for (class, total) in &by_class {
        println!("  {class:<10} summed contribution {}", pct(*total));
    }

    println!("\n== Verdict");
    let labels = [
        "1 pays in crashes",
        "2 cheap in calm years",
        "3 hedges the long sleeves",
        "4 survives dropping top 3",
    ];
    for (label, ok) in labels.iter().zip(pass) {
        println!("  {label:<28} {}", if ok { "PASS" } else { "FAIL" });
    }
    let verdict = if pass.iter().all(|p| *p) {
        "PASS"
    } else {
        "FAIL"
    };
    println!("  overall: {verdict}");

    let out = json!({
        "run_at": Utc::now().to_rfc3339(),
        "verdict": verdict,
        "criteria": labels.iter().zip(pass).map(|(l, p)| json!({"criterion": l, "pass": p})).collect::<Vec<_>>(),
        "crisis_returns_index": c1.iter().map(|(n, r)| json!({"window": n, "return": r})).collect::<Vec<_>>(),
        "crisis_returns_oanda": c1_oanda.iter().map(|(n, r)| json!({"window": n, "return": r})).collect::<Vec<_>>(),
        "oanda_years": years,
        "calm_year_mean": calm,
        "losing_month_correlation": corr,
        "losing_month_mean": mean_in_losses,
        "losing_months": n_losses,
        "dropped_index": drop_idx,
        "dropped_oanda": drop_oanda,
        "crisis_returns_index_without_top3": c1_4.iter().map(|(n, r)| json!({"window": n, "return": r})).collect::<Vec<_>>(),
        "calm_year_mean_without_top3": calm4,
        "losing_month_correlation_without_top3": corr4,
        "sharpe_oanda": sharpe(&oanda_book),
        "sharpe_index": sharpe(&index_book),
        "gross_sharpe_oanda": gross_oanda,
        "gross_sharpe_index": gross_index,
        "class_contribution": by_class,
    });
    let path = Path::new("../research/results/round2_trend_book.json");
    std::fs::create_dir_all(path.parent().expect("results dir"))?;
    std::fs::write(path, serde_json::to_string_pretty(&out)?)?;
    println!("\nwrote {}", path.display());
    Ok(())
}
