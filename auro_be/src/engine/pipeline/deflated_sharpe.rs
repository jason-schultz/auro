//! Deflated Sharpe ratio (Bailey & López de Prado, 2014): the chance a
//! strategy's Sharpe beats what the best of N tries would show by luck alone.
//!
//! N is how many independent tries the idea (`family`) has had. A try is a
//! market (instrument and timeframe; a basket's market list) with a
//! finished pipeline backtest of one set of settings (`settings`: blocks,
//! their settings, rules, stop and hold limit; not sizing or names), or a
//! market research tried outside the pipeline (`research_trials`, one
//! setting each since it records no more). The identical config run twice
//! is one try. The nearby-settings stage's neighbours are never stored as
//! configs, so they are never tries.
//!
//! Settings tried on one market are far from independent: RSI(2), RSI(3)
//! and RSI(4) on SPX trade mostly the same days. Bailey & López de Prado
//! count correlated tries as N̂ = ρ + (1 − ρ)·k, which needs their average
//! correlation ρ; we don't measure it. Instead each market counts as √k
//! tries for its k distinct settings (`count_tries`): 1 setting is 1 try,
//! 4 are 2, 100 are 10. √k is the geometric midpoint of the two ends (all k
//! the same try: 1; all independent: k), it grows with every tweak so
//! retesting is never free, and it grows slower than the tweaks do because
//! nearby settings mostly repeat each other. N is the sum over markets,
//! rounded up. In one sentence: "settings tried on one market overlap, so k
//! settings there count as √k tries".
//!
//! The luck bar is how good the best of N tries would look if none of them
//! had an edge. In t-stat space, z = SR·√(T−1), each such try is about
//! N(0, 1) whatever its trade count, so the bar is the expected best of N
//! standard normals, Z0 = `expected_max(N, 1)`; the strategy's own bar is
//! that z over its √(T−1) (`sharpe_bar`). Its Sharpe is then tested against
//! the bar, allowing for how lopsided and fat-tailed its trade returns are
//! (`deflated_sharpe`).
//!
//! How much the tries' z actually differ (`z_spread`) is recorded for
//! information only and does not set the bar: in families with long
//! backtests it mostly measures real differences between good and bad
//! settings, not luck.
//!
//! Sharpes here are per trade (mean / population spread of trade returns),
//! the backtest stage's `sharpe`, and T is the trade count.

use std::collections::{BTreeMap, BTreeSet};
use std::f64::consts::{E, EULER_GAMMA};

use serde_json::Value;

use crate::engine::options::black_scholes::{norm_cdf, norm_inv};

/// One idea, ignoring names and numbers: the strategy's block types, sorted
/// and de-duplicated, joined with "+" (`"MaFilter+RsiReversion"`). A config
/// without blocks falls back to the block its legacy strategy type stands
/// for, else to the type name itself.
///
/// A basket (`parameters.basket`) is its own idea, apart from the same
/// blocks tried one market at a time: `"Momentum basket"`, or
/// `"Momentum ranked basket"` when it ranks the markets (a different rule).
pub fn family(strategy_type: &str, parameters: &Value) -> String {
    let blocks = block_family(strategy_type, parameters);
    match parameters
        .get("basket")
        .and_then(|b| b.get("mode"))
        .and_then(Value::as_str)
    {
        Some("ranked") => format!("{blocks} ranked basket"),
        Some(_) => format!("{blocks} basket"),
        None => blocks,
    }
}

/// Where a try ran: the market and timeframe (`"SPX500_USD@D"`), or for a
/// basket every market in it (`basket::key`). Settings variants on one
/// market, or one basket, share it (`count_tries`).
pub fn market(instrument: &str, granularity: &str, parameters: &Value) -> String {
    let markets: Option<Vec<&str>> = parameters
        .get("basket")
        .and_then(|b| b.get("markets"))
        .and_then(Value::as_array)
        .map(|ms| ms.iter().filter_map(Value::as_str).collect());
    match markets {
        Some(markets) => super::basket::key(&markets, granularity),
        None => format!("{instrument}@{granularity}"),
    }
}

/// The parts of the strategy JSON that decide its trades: the blocks and
/// their settings, the entry and exit rules, the stop, the hold limit, and
/// for a basket its mode and ranking (its markets are the `market`).
/// Sizing, names, notes and the instrument fields are left out.
const DEFINITION: [&str; 5] = ["components", "entry", "exit", "stop", "max_hold_bars"];

/// A config's settings as one comparable string: `DEFINITION` written with
/// keys sorted and every number as the same float (2 and 2.0 match), a
/// null hold limit the same as none. Two configs on one market are the same
/// try exactly when this matches.
pub fn settings(parameters: &Value) -> String {
    let mut out = String::new();
    let mut parts = serde_json::Map::new();
    for key in DEFINITION {
        if let Some(value) = parameters.get(key).filter(|v| !v.is_null()) {
            parts.insert(key.to_string(), value.clone());
        }
    }
    if let Some(Value::Object(basket)) = parameters.get("basket") {
        let mut basket = basket.clone();
        basket.remove("markets");
        parts.insert("basket".to_string(), Value::Object(basket));
    }
    write_canonical(&Value::Object(parts), &mut out);
    out
}

fn write_canonical(value: &Value, out: &mut String) {
    match value {
        Value::Number(n) => match n.as_f64() {
            Some(x) => out.push_str(&format!("{x:?}")),
            None => out.push_str(&n.to_string()),
        },
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_canonical(item, out);
            }
            out.push(']');
        }
        Value::Object(map) => {
            let sorted: BTreeMap<&String, &Value> = map.iter().collect();
            out.push('{');
            for (i, (key, item)) in sorted.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&Value::String(key.clone()).to_string());
                out.push(':');
                write_canonical(item, out);
            }
            out.push('}');
        }
        other => out.push_str(&other.to_string()),
    }
}

/// How many tries a family has had, and what they come to after allowing
/// for settings on one market repeating each other.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Tries {
    /// Distinct markets tried.
    pub markets: usize,
    /// Distinct (market, settings) tries.
    pub settings: usize,
    /// N for the luck bar: each market counts as √k for its k distinct
    /// settings, summed and rounded up (module doc).
    pub effective: usize,
}

/// Count a family's tries from its pipeline tries, `(market, settings)`
/// pairs (repeats allowed: the same pair twice is one try), and the
/// markets research tried it on (one setting each, unless the pipeline
/// already tried that market).
pub fn count_tries<I>(pipeline: I, research_markets: &[String]) -> Tries
where
    I: IntoIterator<Item = (String, String)>,
{
    let mut per_market: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for (market, settings) in pipeline {
        per_market.entry(market).or_default().insert(settings);
    }
    for market in research_markets {
        per_market.entry(market.clone()).or_default();
    }
    let ks: Vec<usize> = per_market.values().map(|s| s.len().max(1)).collect();
    let weight: f64 = ks.iter().map(|&k| (k as f64).sqrt()).sum();
    Tries {
        markets: ks.len(),
        settings: ks.iter().sum(),
        // A hair under, so a sum of whole roots (1 + 1, √4) isn't pushed
        // up by float error.
        effective: (weight - 1e-9).ceil().max(0.0) as usize,
    }
}

fn block_family(strategy_type: &str, parameters: &Value) -> String {
    let types: BTreeSet<&str> = parameters
        .get("components")
        .and_then(Value::as_object)
        .into_iter()
        .flat_map(|components| components.values())
        .filter_map(|c| c.get("type").and_then(Value::as_str))
        .collect();
    if !types.is_empty() {
        return types.into_iter().collect::<Vec<_>>().join("+");
    }
    match strategy_type {
        "mean_reversion" => "MeanReversion",
        "trend_following" => "TrendFollowing",
        "donchian" => "Donchian",
        "rsi2_dipbuy" => "MaFilter+RsiReversion",
        other => other,
    }
    .to_string()
}

/// Sample variance (N − 1). None with fewer than two values.
pub fn sample_variance(values: &[f64]) -> Option<f64> {
    let n = values.len();
    if n < 2 {
        return None;
    }
    let mean = values.iter().sum::<f64>() / n as f64;
    Some(values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / (n - 1) as f64)
}

/// A try's Sharpe as a t-stat: SR·√(T−1), on the same footing as the
/// deflated Sharpe's own test. 0 with no trades.
pub fn z_score(sharpe: f64, trades: usize) -> f64 {
    sharpe * (trades.saturating_sub(1) as f64).sqrt()
}

/// How much the tries' t-stats differ: information only, not used for the
/// luck bar.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ZSpread {
    /// Sample variance of their z. None with fewer than two tries.
    pub raw: Option<f64>,
    /// How many tries it was measured on.
    pub tries: usize,
}

/// The spread of the tries' z from `(sharpe, trades)` pairs. Tries with
/// fewer than `min_trades` (the backtest's own minimum; at least 2) are
/// left out: a handful of trades gives a Sharpe too wild to measure the
/// spread with.
pub fn z_spread(tries: &[(f64, usize)], min_trades: usize) -> ZSpread {
    let zs: Vec<f64> = tries
        .iter()
        .filter(|(_, t)| *t >= min_trades.max(2))
        .map(|(sr, t)| z_score(*sr, *t))
        .collect();
    ZSpread {
        raw: sample_variance(&zs),
        tries: zs.len(),
    }
}

/// Skewness and (plain, not excess: a normal is 3) kurtosis of returns,
/// from population moments like the per-trade Sharpe's spread. None with
/// fewer than two returns or no spread.
pub fn skew_kurtosis(returns: &[f64]) -> Option<(f64, f64)> {
    let n = returns.len() as f64;
    if returns.len() < 2 {
        return None;
    }
    let mean = returns.iter().sum::<f64>() / n;
    let moment = |k: i32| returns.iter().map(|r| (r - mean).powi(k)).sum::<f64>() / n;
    let m2 = moment(2);
    if m2 <= 0.0 {
        return None;
    }
    Some((moment(3) / m2.powf(1.5), moment(4) / (m2 * m2)))
}

/// What the best of `n_trials` tries reaches by luck alone when their
/// scores vary by `variance`: √V·((1−γ)·Φ⁻¹(1−1/N) + γ·Φ⁻¹(1−1/(N·e))).
/// With variance 1, in t-stat space, it is Z0: how good the best of N tries
/// would look if none had an edge. 0 with fewer than two tries,
/// which leaves the plain probabilistic Sharpe ratio (is the Sharpe above
/// zero).
pub fn expected_max(n_trials: usize, variance: f64) -> f64 {
    if n_trials < 2 || !(variance.is_finite() && variance > 0.0) {
        return 0.0;
    }
    let n = n_trials as f64;
    variance.sqrt()
        * ((1.0 - EULER_GAMMA) * norm_inv(1.0 - 1.0 / n)
            + EULER_GAMMA * norm_inv(1.0 - 1.0 / (n * E)))
}

/// The per-trade Sharpe a strategy with `trades` trades must beat: the luck
/// t-stat `z0` brought back to its own length, Z0 / √(T−1). 0 with fewer
/// than two trades (its deflated Sharpe can't be computed anyway).
pub fn sharpe_bar(z0: f64, trades: usize) -> f64 {
    if trades < 2 {
        return 0.0;
    }
    z0 / ((trades - 1) as f64).sqrt()
}

/// Φ((SR − SR0)·√(T−1) / √(1 − skew·SR + (kurt−1)/4·SR²)): the chance the
/// true Sharpe is above `sr0`. None when it can't be computed (fewer than
/// two trades, or returns so lopsided the spread term is not positive).
pub fn deflated_sharpe(sr: f64, sr0: f64, trades: usize, skew: f64, kurtosis: f64) -> Option<f64> {
    if trades < 2 {
        return None;
    }
    let spread = 1.0 - skew * sr + (kurtosis - 1.0) / 4.0 * sr * sr;
    if !(spread.is_finite() && spread > 0.0) {
        return None;
    }
    let z = (sr - sr0) * ((trades - 1) as f64).sqrt() / spread.sqrt();
    z.is_finite().then(|| norm_cdf(z))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn close(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() < tol
    }

    #[test]
    fn the_family_is_the_sorted_set_of_block_types() {
        let params = json!({"components": {
            "trend": {"type": "MaFilter", "params": {"period": 200}},
            "r": {"type": "RsiReversion", "params": {"rsi_period": 2}},
            "exit_ma": {"type": "MaFilter", "params": {"period": 5}},
        }});
        assert_eq!(family("composite", &params), "MaFilter+RsiReversion");
        // Names, numbers and the legacy type don't matter when there are blocks.
        assert_eq!(family("rsi2_dipbuy", &params), "MaFilter+RsiReversion");
    }

    #[test]
    fn a_basket_is_its_own_family_and_one_try_per_market_list() {
        let blocks = json!({"m": {"type": "Momentum", "params": {"lookback": 252}}});
        let together = json!({"components": blocks,
            "basket": {"markets": ["SPX500_USD", "XAU_USD"], "mode": "together"}});
        let ranked = json!({"components": blocks,
            "basket": {"markets": ["SPX500_USD", "XAU_USD"], "mode": "ranked"}});
        assert_eq!(
            family("composite", &json!({"components": blocks})),
            "Momentum"
        );
        assert_eq!(family("composite", &together), "Momentum basket");
        assert_eq!(family("composite", &ranked), "Momentum ranked basket");

        assert_eq!(
            market("SPX500_USD", "D", &together),
            "BASKET(SPX500_USD,XAU_USD)@D"
        );
        assert_eq!(market("SPX500_USD", "D", &json!({})), "SPX500_USD@D");
    }

    #[test]
    fn settings_ignore_names_sizing_key_order_and_number_spelling() {
        let a = json!({
            "strategy_name": "rsi2 SPX", "strategy_id": null, "version": "v1_composite",
            "instrument": "SPX500_USD", "granularity": "D", "source_note": "Connors",
            "components": {"r": {"type": "RsiReversion", "params": {"rsi_period": 2, "oversold": 10}}},
            "entry": {"long": "r.oversold"}, "exit": {"long": "r.overbought"},
            "stop": {"type": "FixedPct", "params": {"pct": -0.02}},
            "sizing": {"type": "RiskPct", "params": {"pct": 1.0}},
            "max_hold_bars": null,
        });
        let b = json!({
            "stop": {"params": {"pct": -0.02}, "type": "FixedPct"},
            "exit": {"long": "r.overbought"}, "entry": {"long": "r.oversold"},
            "components": {"r": {"params": {"oversold": 10.0, "rsi_period": 2.0}, "type": "RsiReversion"}},
            "sizing": {"type": "RiskPct", "params": {"pct": 2.5}},
            "strategy_name": "renamed",
        });
        assert_eq!(settings(&a), settings(&b));

        let mut rsi3 = b.clone();
        rsi3["components"]["r"]["params"]["rsi_period"] = json!(3);
        assert_ne!(settings(&a), settings(&rsi3));
        let mut held = b.clone();
        held["max_hold_bars"] = json!(10);
        assert_ne!(settings(&a), settings(&held));
        let mut rule = b.clone();
        rule["entry"]["long"] = json!({"within": 3, "rule": "r.oversold"});
        assert_ne!(settings(&a), settings(&rule));
    }

    #[test]
    fn a_baskets_settings_are_its_mode_and_ranking_not_its_markets() {
        let basket = |markets: &[&str], every: u64| {
            json!({"components": {"m": {"type": "Momentum", "params": {"lookback": 252}}},
                "basket": {"markets": markets, "mode": "ranked",
                    "rank": {"by": "m.roc", "every_bars": every, "long_top": 1, "short_bottom": 1}}})
        };
        assert_eq!(
            settings(&basket(&["A", "B"], 21)),
            settings(&basket(&["A", "C"], 21))
        );
        assert_ne!(
            settings(&basket(&["A", "B"], 21)),
            settings(&basket(&["A", "B"], 5))
        );
    }

    #[test]
    fn each_market_counts_as_the_root_of_its_distinct_settings() {
        let tries = |pairs: &[(&str, &str)]| -> Vec<(String, String)> {
            pairs
                .iter()
                .map(|(m, s)| (m.to_string(), s.to_string()))
                .collect()
        };
        // One market, one setting run twice: one try.
        let rerun = count_tries(tries(&[("SPX@D", "a"), ("SPX@D", "a")]), &[]);
        assert_eq!(
            rerun,
            Tries {
                markets: 1,
                settings: 1,
                effective: 1
            }
        );
        // Four settings on SPX count as 2; one on each of two more markets, 1 each.
        let four = tries(&[
            ("SPX@D", "a"),
            ("SPX@D", "b"),
            ("SPX@D", "c"),
            ("SPX@D", "d"),
            ("NAS@D", "a"),
            ("DAX@D", "a"),
        ]);
        assert_eq!(
            count_tries(four.clone(), &[]),
            Tries {
                markets: 3,
                settings: 6,
                effective: 4
            }
        );
        // Two settings on one market: √2 rounds up, so a tweak is never free.
        assert_eq!(
            count_tries(tries(&[("SPX@D", "a"), ("SPX@D", "b")]), &[]).effective,
            2
        );
        // Research adds a new market as one setting; a known one adds nothing.
        let research = vec!["SPX@D".to_string(), "FTSE@D".to_string()];
        assert_eq!(
            count_tries(four, &research),
            Tries {
                markets: 4,
                settings: 7,
                effective: 5
            }
        );
        assert_eq!(count_tries(Vec::new(), &[]).effective, 0);
        // A hundred settings on one market count as ten tries.
        let hundred: Vec<(String, String)> = (0..100)
            .map(|i| ("SPX@D".to_string(), i.to_string()))
            .collect();
        assert_eq!(count_tries(hundred, &[]).effective, 10);
    }

    #[test]
    fn a_config_without_blocks_uses_its_legacy_type() {
        assert_eq!(family("mean_reversion", &json!({})), "MeanReversion");
        assert_eq!(family("trend_following", &json!({})), "TrendFollowing");
        assert_eq!(family("donchian", &json!({"components": {}})), "Donchian");
        assert_eq!(family("rsi2_dipbuy", &json!({})), "MaFilter+RsiReversion");
        assert_eq!(family("something_new", &json!({})), "something_new");
    }

    #[test]
    fn moments_of_a_symmetric_two_point_spread() {
        // ±1 equally often: no lean, and the thinnest tails there are (1).
        let (skew, kurt) = skew_kurtosis(&[1.0, -1.0, 1.0, -1.0]).unwrap();
        assert!(close(skew, 0.0, 1e-12));
        assert!(close(kurt, 1.0, 1e-12));
        assert!(skew_kurtosis(&[0.5, 0.5]).is_none());
        assert!(skew_kurtosis(&[0.5]).is_none());
    }

    #[test]
    fn one_try_or_no_spread_leaves_the_plain_probabilistic_sharpe() {
        assert_eq!(expected_max(1, 4.0), 0.0);
        assert_eq!(expected_max(100, 0.0), 0.0);
        // Against a bar of 0 with normal returns (skew 0, kurtosis 3):
        // Φ(0.1·√99 / √(1 + 0.5·0.01)) = Φ(0.9925).
        let dsr = deflated_sharpe(0.1, 0.0, 100, 0.0, 3.0).unwrap();
        assert!(close(dsr, 0.8395, 1e-4), "{dsr}");
    }

    /// The paper's worked example (Bailey & López de Prado 2014, §"A
    /// numerical example"): 100 tries whose annual Sharpes vary by 0.5, the
    /// best at 2.5 a year over 1,250 daily returns, skew −3, kurtosis 10.
    /// In daily units V = 0.5/250 and SR = 2.5/√250; the paper gets a luck
    /// bar of 0.1132 a day and a deflated Sharpe of 0.9004. Checked by hand:
    /// Φ⁻¹(0.99) = 2.3263, Φ⁻¹(1 − 1/(100e)) = 2.6800, so
    /// SR0 = 0.04472·(0.4228·2.3263 + 0.5772·2.6800) = 0.1132, and
    /// z = (0.15811 − 0.1132)·√1249 / √(1 + 3·0.15811 + 2.25·0.025) = 1.284.
    #[test]
    fn matches_the_papers_worked_example() {
        let sr0 = expected_max(100, 0.5 / 250.0);
        assert!(close(sr0, 0.1132, 1e-4), "{sr0}");

        let sr = 2.5 / 250f64.sqrt();
        let dsr = deflated_sharpe(sr, sr0, 1250, -3.0, 10.0).unwrap();
        assert!(close(dsr, 0.9004, 1e-3), "{dsr}");
    }

    #[test]
    fn more_tries_raise_the_luck_bar() {
        let few = expected_max(10, 1.0);
        let many = expected_max(1000, 1.0);
        assert!(few > 0.0 && many > few);
    }

    #[test]
    fn an_impossible_spread_term_is_not_a_number() {
        // 1 − 5·1 + (1−1)/4 < 0: returns too lopsided for the formula.
        assert!(deflated_sharpe(1.0, 0.0, 50, 5.0, 1.0).is_none());
        assert!(deflated_sharpe(0.2, 0.0, 1, 0.0, 3.0).is_none());
    }

    #[test]
    fn a_try_is_scored_as_its_t_stat() {
        assert!(close(z_score(0.2, 101), 2.0, 1e-12));
        assert_eq!(z_score(0.5, 0), 0.0);
    }

    #[test]
    fn the_bar_is_the_best_of_n_tries_with_no_edge() {
        // 100 tries with no edge: the best t-stat is about 2.53, and over
        // 101 trades that's a per-trade Sharpe of 0.253.
        let z0 = expected_max(100, 1.0);
        assert!(close(z0, 2.5306, 1e-3), "{z0}");
        assert!(close(sharpe_bar(z0, 101), z0 / 10.0, 1e-12));
        // More tries, higher bar; one try, no bar.
        assert!(expected_max(1000, 1.0) > z0);
        assert_eq!(expected_max(1, 1.0), 0.0);
        assert_eq!(sharpe_bar(z0, 1), 0.0);
    }

    #[test]
    fn the_spread_is_measured_on_full_sized_tries_only() {
        // t-stats 0 and 4 over 101 trades: variance 8.
        let tries = [(0.0, 101), (0.4, 101), (-48.6, 2), (3.0, 29)];
        let spread = z_spread(&tries, 30);
        assert_eq!(spread.tries, 2);
        assert!(close(spread.raw.unwrap(), 8.0, 1e-9));
        assert_eq!(z_spread(&[(0.3, 101)], 30).raw, None);
        // The minimum never drops below 2: one trade has no spread.
        assert_eq!(z_spread(&[(0.1, 1), (0.2, 1)], 0).tries, 0);
    }

    #[test]
    fn sample_variance_divides_by_n_minus_one() {
        assert!(close(sample_variance(&[1.0, 3.0]).unwrap(), 2.0, 1e-12));
        assert!(sample_variance(&[1.0]).is_none());
    }
}
