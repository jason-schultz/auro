//! Shared evaluation for the index-exposure research rounds (3 and 4): the
//! daily returns of an exposure series on an index, the crash and scare
//! windows, and the de-risk pass criteria both rounds pre-registered.
//!
//! Included with `#[path = "common/index_eval.rs"] mod index_eval;` so the
//! other research examples don't compile it.

use std::collections::BTreeMap;

use chrono::NaiveDate;

use crate::common::mean_std;

pub const TRADING_DAYS: f64 = 252.0;
/// Cost per unit of exposure traded.
const SWITCH_COST: f64 = 0.0002;
const CRASH_SAVING: f64 = 0.25;
const DRAWDOWN_RATIO: f64 = 2.0 / 3.0;

pub type Ymd = (i32, u32, u32);

const START: Ymd = (1991, 1, 1);

pub const CRASHES: [(&str, Ymd, Ymd); 4] = [
    ("dot-com", (2000, 3, 24), (2002, 10, 9)),
    ("housing", (2007, 10, 9), (2009, 3, 9)),
    ("covid", (2020, 2, 19), (2020, 3, 23)),
    ("2022 bear", (2022, 1, 3), (2022, 10, 12)),
];

pub const SCARES: [(&str, Ymd, Ymd); 7] = [
    ("Asia 1997", (1997, 10, 1), (1997, 10, 31)),
    ("LTCM/Russia 1998", (1998, 8, 1), (1998, 10, 15)),
    ("euro debt 2011", (2011, 7, 1), (2011, 10, 31)),
    ("China 2015-16", (2015, 8, 1), (2016, 2, 29)),
    ("Brexit 2016", (2016, 6, 15), (2016, 7, 15)),
    ("late 2018", (2018, 10, 1), (2018, 12, 31)),
    ("SVB 2023", (2023, 3, 1), (2023, 3, 31)),
];

pub fn ymd((y, m, d): Ymd) -> NaiveDate {
    NaiveDate::from_ymd_opt(y, m, d).expect("valid date")
}

/// Prices from 1991 on, as parallel date and close vectors.
pub fn from_start(closes: &BTreeMap<NaiveDate, f64>) -> (Vec<NaiveDate>, Vec<f64>) {
    closes.range(ymd(START)..).map(|(d, c)| (*d, *c)).unzip()
}

/// Daily returns of holding `exposure[i]` of the index over day i (decided at
/// the previous close). Exposure earns the price move plus the dividend
/// estimate; the rest earns nothing; every unit traded costs 2 bp.
pub fn exposure_returns(prices: &[f64], dividend: f64, exposure: &[f64]) -> Vec<f64> {
    let carry = dividend / TRADING_DAYS;
    let mut out = vec![0.0; prices.len()];
    for i in 1..prices.len() {
        let r = prices[i] / prices[i - 1] - 1.0;
        let traded = if i >= 2 {
            (exposure[i] - exposure[i - 1]).abs()
        } else {
            0.0
        };
        out[i] = exposure[i] * (r + carry) - traded * SWITCH_COST;
    }
    out
}

pub fn compound(dates: &[NaiveDate], returns: &[f64], from: NaiveDate, to: NaiveDate) -> f64 {
    dates
        .iter()
        .zip(returns)
        .filter(|(d, _)| **d > from && **d <= to)
        .fold(1.0, |acc, (_, r)| acc * (1.0 + r))
        - 1.0
}

fn sharpe(returns: &[f64]) -> f64 {
    let (m, sd) = mean_std(returns);
    m / sd * TRADING_DAYS.sqrt()
}

fn max_drawdown(returns: &[f64]) -> f64 {
    let mut peak = 1.0f64;
    let mut equity = 1.0f64;
    let mut worst = 0.0f64;
    for r in returns {
        equity *= 1.0 + r;
        peak = peak.max(equity);
        worst = worst.min(equity / peak - 1.0);
    }
    worst
}

pub fn pct(x: f64) -> String {
    format!("{:+.1}%", x * 100.0)
}

/// A strategy against buy-and-hold on the pre-registered de-risk criteria.
pub struct Scorecard {
    /// (window, buy-and-hold, strategy) per crash.
    pub crashes: Vec<(&'static str, f64, f64)>,
    /// Criterion 1: at least 25% less loss than buy-and-hold in every crash.
    pub avoids_crashes: bool,
    pub sharpe_hold: f64,
    pub sharpe: f64,
    pub drawdown_hold: f64,
    pub drawdown: f64,
    /// Criterion 2: Sharpe at least buy-and-hold's, worst drawdown at most
    /// two-thirds of buy-and-hold's.
    pub worth_it: bool,
}

pub fn score(dates: &[NaiveDate], hold: &[f64], strategy: &[f64]) -> Scorecard {
    let crashes: Vec<(&'static str, f64, f64)> = CRASHES
        .iter()
        .map(|(label, a, b)| {
            let (a, b) = (ymd(*a), ymd(*b));
            (
                *label,
                compound(dates, hold, a, b),
                compound(dates, strategy, a, b),
            )
        })
        .collect();
    let avoids_crashes = crashes
        .iter()
        .all(|(_, hold, s)| *s >= hold * (1.0 - CRASH_SAVING));
    let (sharpe_hold, sharpe) = (sharpe(&hold[1..]), sharpe(&strategy[1..]));
    let (drawdown_hold, drawdown) = (max_drawdown(hold), max_drawdown(strategy));
    Scorecard {
        crashes,
        avoids_crashes,
        sharpe_hold,
        sharpe,
        drawdown_hold,
        drawdown,
        worth_it: sharpe >= sharpe_hold && drawdown >= drawdown_hold * DRAWDOWN_RATIO,
    }
}
