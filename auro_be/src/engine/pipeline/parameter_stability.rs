//! Parameter stability: a real edge doesn't hinge on one exact setting.
//!
//! Every number in the strategy's blocks and stop (not sizing: risk per
//! trade doesn't change a trade's return) gets a lower and a higher
//! neighbour, about 10% either way: whole numbers by max(1, 10% rounded),
//! the rest by exactly 10% (`neighbours`). A neighbour outside the range
//! where its block means anything (`strategy::setting_range`) is skipped
//! with the reason.
//!
//! The bar counts in time rules (`{"within": N, "rule": ..}`,
//! `{"ago": N, "rule": ..}` in the entry and exit) move the same way, by
//! max(1, 10% rounded), kept within 1..=`RULE_LOOKBACK_MAX`. A ranked
//! basket's `every_bars` (bars between rebalances) moves too; how many
//! markets it buys and sells (`long_top`, `short_bottom`) stay fixed: they
//! are counts of positions, not a dial, and a step of one is a different
//! portfolio, not a nearby one. Hold limits and sizing never move.
//!
//! Each neighbour that runs is backtested like the original; the strategy passes when every neighbour
//! still makes money and keeps at least half the original's Sharpe. Those
//! two bars are `validation_thresholds` rows on the aggregate
//! `worst_total_return` and `worst_sharpe_retention`, and the same rows judge
//! each neighbour (`neighbour_passes`) so the page can say which one broke it.
//!
//! Neighbours are run in memory and never stored as configs, so the luck
//! check never counts them as tries (`deflated_sharpe`): they are the
//! robustness check, not more searching.

use serde_json::Value;

use super::{apply_threshold, ThresholdRow};
use crate::engine::strategy::{setting_range, RULE_LOOKBACK_MAX};

/// How far a setting moves either way, as a share of its value.
const STEP: f64 = 0.10;

/// One setting moved one step.
#[derive(Debug, Clone, PartialEq)]
pub struct Neighbour {
    /// `"<block name>.<setting>"`, `"stop.<setting>"`, a time rule's
    /// `"entry.long.within"` (`"…within#2"` for a second one on that side),
    /// or `"basket.every_bars"`.
    pub setting: String,
    /// The block's type (`"RsiReversion"`), the stop's (`"AtrMultiple"`),
    /// `"time rule"` or `"ranked basket"`.
    pub kind: String,
    /// What moved, in words: `"rsi period (r, RsiReversion)"`.
    pub label: String,
    pub from: f64,
    pub to: f64,
    /// The whole strategy JSON with this one setting moved.
    pub parameters: Value,
    /// Why it isn't worth running: the setting left the range where its
    /// block means anything. None: run it.
    pub skip: Option<&'static str>,
}

/// Every numeric setting's two neighbours, blocks first (by name) then the
/// stop, in setting-name order; then the time rules' bar counts (entry
/// then exit, long then short, depth first) and a ranked basket's
/// `every_bars` when `strategy` carries its `basket`. `strategy` is the parsed strategy written
/// back out, so settings left at their defaults are present and floats are
/// written as floats (a stored `20` for a float setting reads as `20.0`).
/// A float setting at 0 has no ±10% neighbour and is left out.
pub fn neighbours(strategy: &Value) -> Vec<Neighbour> {
    let mut slots: Vec<(String, String, &serde_json::Map<String, Value>, String)> = Vec::new();
    if let Some(components) = strategy.get("components").and_then(Value::as_object) {
        for (name, component) in components {
            if let (Some(kind), Some(params)) = (
                component.get("type").and_then(Value::as_str),
                component.get("params").and_then(Value::as_object),
            ) {
                slots.push((
                    name.clone(),
                    kind.to_string(),
                    params,
                    format!("/components/{}/params", pointer_escape(name)),
                ));
            }
        }
    }
    if let Some(stop) = strategy.get("stop") {
        if let (Some(kind), Some(params)) = (
            stop.get("type").and_then(Value::as_str),
            stop.get("params").and_then(Value::as_object),
        ) {
            slots.push((
                "stop".to_string(),
                kind.to_string(),
                params,
                "/stop/params".to_string(),
            ));
        }
    }

    let mut out = Vec::new();
    for (name, kind, params, base) in slots {
        for (key, value) in params {
            let Some(from) = value.as_f64() else { continue };
            let steps: [f64; 2] = if value.is_f64() {
                if from == 0.0 {
                    continue;
                }
                [
                    round_step(from * (1.0 - STEP)),
                    round_step(from * (1.0 + STEP)),
                ]
            } else {
                let step = (from.abs() * STEP).round().max(1.0);
                [from - step, from + step]
            };
            let range = setting_range(&kind, key);
            let pointer = format!("{base}/{}", pointer_escape(key));
            for to in steps {
                let skip = range.filter(|r| to < r.min || to > r.max).map(|r| r.why);
                let mut parameters = strategy.clone();
                if let Some(slot) = parameters.pointer_mut(&pointer) {
                    *slot = if value.is_f64() {
                        Value::from(to)
                    } else {
                        Value::from(to as i64)
                    };
                    out.push(Neighbour {
                        setting: format!("{name}.{key}"),
                        kind: kind.clone(),
                        label: format!("{} ({name}, {kind})", key.replace('_', " ")),
                        from,
                        to,
                        parameters,
                        skip,
                    });
                }
            }
        }
    }
    for side in ["entry", "exit"] {
        for direction in ["long", "short"] {
            let pointer = format!("/{side}/{direction}");
            let mut rules = Vec::new();
            if let Some(rule) = strategy.pointer(&pointer) {
                time_rules(rule, &pointer, &mut rules);
            }
            let mut seen: Vec<&str> = Vec::new();
            for (at, key, from) in rules {
                let nth = seen.iter().filter(|k| **k == key).count() + 1;
                seen.push(key);
                let suffix = if nth > 1 {
                    format!("#{nth}")
                } else {
                    String::new()
                };
                let place = if nth > 1 {
                    format!(" (number {nth})")
                } else {
                    String::new()
                };
                for to in count_steps(from) {
                    out.extend(moved(
                        strategy,
                        &at,
                        Neighbour {
                            setting: format!("{side}.{direction}.{key}{suffix}"),
                            kind: "time rule".to_string(),
                            label: format!(
                                "the \"{key}\" bars of the {direction} {side} rule{place}"
                            ),
                            from: from as f64,
                            to: to as f64,
                            parameters: Value::Null,
                            skip: if to < 1 {
                                Some("a time rule counts at least 1 bar")
                            } else if to > RULE_LOOKBACK_MAX as i64 {
                                Some("a time rule can't count more bars than the builder allows")
                            } else {
                                None
                            },
                        },
                    ));
                }
            }
        }
    }
    let every = "/basket/rank/every_bars";
    if let Some(from) = strategy.pointer(every).and_then(Value::as_u64) {
        for to in count_steps(from) {
            out.extend(moved(
                strategy,
                every,
                Neighbour {
                    setting: "basket.every_bars".to_string(),
                    kind: "ranked basket".to_string(),
                    label: "bars between rebalances (ranked basket)".to_string(),
                    from: from as f64,
                    to: to as f64,
                    parameters: Value::Null,
                    skip: (to < 1).then_some("a ranked basket rebalances at least every bar"),
                },
            ));
        }
    }
    out
}

/// A whole-number count's two neighbours: max(1, 10% rounded) either way.
fn count_steps(from: u64) -> [i64; 2] {
    let from = from as i64;
    let step = ((from as f64) * STEP).round().max(1.0) as i64;
    [from - step, from + step]
}

/// `neighbour` with `strategy` as its parameters and the count at
/// `pointer` set to its `to`. None when nothing is there.
fn moved(strategy: &Value, pointer: &str, neighbour: Neighbour) -> Option<Neighbour> {
    let mut parameters = strategy.clone();
    *parameters.pointer_mut(pointer)? = Value::from(neighbour.to as i64);
    Some(Neighbour {
        parameters,
        ..neighbour
    })
}

/// Every `within` / `ago` bar count in a rule, depth first: its JSON
/// pointer, which one it is, and its value.
fn time_rules(rule: &Value, at: &str, out: &mut Vec<(String, &'static str, u64)>) {
    let Some(map) = rule.as_object() else { return };
    for key in ["within", "ago"] {
        if let Some(n) = map.get(key).and_then(Value::as_u64) {
            out.push((format!("{at}/{key}"), key, n));
        }
    }
    if let Some(inner) = map.get("rule") {
        time_rules(inner, &format!("{at}/rule"), out);
    }
    if let Some(inner) = map.get("not") {
        time_rules(inner, &format!("{at}/not"), out);
    }
    for key in ["and", "or"] {
        if let Some(items) = map.get(key).and_then(Value::as_array) {
            for (i, item) in items.iter().enumerate() {
                time_rules(item, &format!("{at}/{key}/{i}"), out);
            }
        }
    }
}

/// A JSON-pointer path segment (RFC 6901): `~` and `/` escaped.
fn pointer_escape(segment: &str) -> String {
    segment.replace('~', "~0").replace('/', "~1")
}

/// ±10% of 0.15 is 0.16500000000000001 in floating point; keep it 0.165.
fn round_step(x: f64) -> f64 {
    (x * 1e10).round() / 1e10
}

/// Whether one neighbour clears the stage's bars: the rows on
/// `worst_sharpe_retention` and `worst_total_return` applied to this
/// neighbour alone. Rows on other metrics don't apply to a single neighbour.
pub fn neighbour_passes(thresholds: &[ThresholdRow], retention: f64, total_return: f64) -> bool {
    thresholds.iter().all(|t| {
        let actual = match t.metric.as_str() {
            "worst_sharpe_retention" => retention,
            "worst_total_return" => total_return,
            _ => return true,
        };
        apply_threshold(&t.operator, actual, t.value)
    })
}

/// "Moving rsi period (r, RsiReversion) from 2 to 3 dropped the Sharpe from
/// 0.42 to 0.11", or "… left it losing money (−1.20%)" when the Sharpe held
/// but the return didn't.
pub fn failure_words(
    n: &Neighbour,
    base_sharpe: f64,
    sharpe: f64,
    total_return: f64,
    retention_ok: bool,
) -> String {
    let effect = if retention_ok {
        format!("left it not making money ({:+.2}%)", total_return * 100.0)
    } else {
        format!("dropped the Sharpe from {base_sharpe:.2} to {sharpe:.2}")
    };
    format!(
        "Moving {} from {} to {} {effect}",
        n.label,
        number(n.from),
        number(n.to)
    )
}

/// A setting as a person writes it: 2, 0.165, −0.022.
fn number(x: f64) -> String {
    format!("{}", round_step(x))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn row(metric: &str, operator: &str, value: f64) -> ThresholdRow {
        ThresholdRow {
            metric: metric.to_string(),
            operator: operator.to_string(),
            value,
        }
    }

    fn strategy() -> Value {
        json!({
            "components": {
                "r": {"type": "RsiReversion",
                      "params": {"rsi_period": 2, "oversold": 10.0, "overbought": 90.0}},
                "t": {"type": "MaFilter", "params": {"period": 200, "ma_type": "sma"}},
            },
            "stop": {"type": "FixedPct", "params": {"pct": -0.02}},
            "sizing": {"type": "RiskPct", "params": {"pct": 1.0}},
            "max_hold_bars": 10,
        })
    }

    #[test]
    fn settings_move_about_ten_percent_and_whole_numbers_at_least_one() {
        let moves: Vec<(String, f64, f64)> = neighbours(&strategy())
            .into_iter()
            .map(|n| (n.setting, n.from, n.to))
            .collect();
        assert_eq!(
            moves,
            vec![
                ("r.overbought".into(), 90.0, 81.0),
                ("r.overbought".into(), 90.0, 99.0),
                ("r.oversold".into(), 10.0, 9.0),
                ("r.oversold".into(), 10.0, 11.0),
                ("r.rsi_period".into(), 2.0, 1.0),
                ("r.rsi_period".into(), 2.0, 3.0),
                ("t.period".into(), 200.0, 180.0),
                ("t.period".into(), 200.0, 220.0),
                ("stop.pct".into(), -0.02, -0.018),
                ("stop.pct".into(), -0.02, -0.022),
            ]
        );
    }

    #[test]
    fn whole_number_steps_round_to_the_nearest_bar() {
        // 10% of 14 is 1.4 → 1; of 15, 1.5 → 2; of 5, 0.5 → at least 1.
        let s = json!({"components": {
            "a": {"type": "AdxFilter", "params": {"period": 14, "threshold": 25.0}},
            "m": {"type": "Momentum", "params": {"lookback": 15}},
            "v": {"type": "Volatility", "params": {"period": 5, "baseline": 100}}}});
        let moves: Vec<(String, f64)> = neighbours(&s)
            .into_iter()
            .filter(|n| !n.setting.ends_with("threshold"))
            .map(|n| (n.setting, n.to))
            .collect();
        assert_eq!(
            moves,
            vec![
                ("a.period".into(), 13.0),
                ("a.period".into(), 15.0),
                ("m.lookback".into(), 13.0),
                ("m.lookback".into(), 17.0),
                ("v.baseline".into(), 90.0),
                ("v.baseline".into(), 110.0),
                ("v.period".into(), 4.0),
                ("v.period".into(), 6.0),
            ]
        );
    }

    #[test]
    fn a_move_out_of_the_blocks_meaningful_range_is_marked_skipped() {
        let s = json!({"components": {
            "r": {"type": "RsiReversion",
                  "params": {"rsi_period": 2, "oversold": 10.0, "overbought": 95.0}}}});
        let skipped: Vec<(String, f64)> = neighbours(&s)
            .into_iter()
            .filter(|n| n.skip.is_some())
            .map(|n| (n.setting, n.to))
            .collect();
        // RSI over 1 bar, and an overbought level of 104.5.
        assert_eq!(
            skipped,
            vec![("r.overbought".into(), 104.5), ("r.rsi_period".into(), 1.0)]
        );
        let rsi_down = neighbours(&s)
            .into_iter()
            .find(|n| n.setting == "r.rsi_period" && n.to == 1.0)
            .unwrap();
        assert_eq!(
            rsi_down.skip,
            Some("an RSI over fewer than 2 bars only reads 0 or 100")
        );
    }

    #[test]
    fn a_neighbour_changes_only_its_own_setting_and_keeps_its_kind() {
        let all = neighbours(&strategy());
        let period_up = all
            .iter()
            .find(|n| n.setting == "r.rsi_period" && n.to == 3.0);
        let p = &period_up.unwrap().parameters;
        assert_eq!(p["components"]["r"]["params"]["rsi_period"], json!(3));
        assert_eq!(p["components"]["r"]["params"]["oversold"], json!(10.0));
        assert_eq!(p["components"]["t"]["params"]["ma_type"], json!("sma"));
        // Sizing and the hold limit are never moved.
        assert!(all.iter().all(|n| !n.setting.starts_with("sizing")));
        assert_eq!(p["sizing"], strategy()["sizing"]);
        assert_eq!(p["max_hold_bars"], json!(10));
    }

    #[test]
    fn time_rule_bar_counts_move_by_at_least_one_within_their_range() {
        let s = json!({
            "components": {"r": {"type": "Vwap", "params": {}}},
            "entry": {"long": {"and": ["r.above", {"within": 20, "rule": {"ago": 1, "rule": "r.cross"}}]},
                      "short": {"within": 3, "rule": "r.below"}},
            "exit": {"long": {"not": {"ago": 500, "rule": "r.x"}}},
        });
        let moves: Vec<(String, f64, f64, Option<&str>)> = neighbours(&s)
            .into_iter()
            .map(|n| (n.setting, n.from, n.to, n.skip))
            .collect();
        assert_eq!(
            moves,
            vec![
                ("entry.long.within".into(), 20.0, 18.0, None),
                ("entry.long.within".into(), 20.0, 22.0, None),
                (
                    "entry.long.ago".into(),
                    1.0,
                    0.0,
                    Some("a time rule counts at least 1 bar")
                ),
                ("entry.long.ago".into(), 1.0, 2.0, None),
                ("entry.short.within".into(), 3.0, 2.0, None),
                ("entry.short.within".into(), 3.0, 4.0, None),
                ("exit.long.ago".into(), 500.0, 450.0, None),
                (
                    "exit.long.ago".into(),
                    500.0,
                    550.0,
                    Some("a time rule can't count more bars than the builder allows")
                ),
            ]
        );
        let up = neighbours(&s)
            .into_iter()
            .find(|n| n.setting == "entry.long.within" && n.to == 22.0)
            .unwrap();
        // Only that count moved, written as a whole number.
        assert_eq!(
            up.parameters["entry"]["long"]["and"][1]["within"],
            json!(22)
        );
        assert_eq!(
            up.parameters["entry"]["long"]["and"][1]["rule"]["ago"],
            json!(1)
        );
        assert_eq!(up.parameters["entry"]["short"], s["entry"]["short"]);
        assert_eq!(
            failure_words(&up, 0.4, 0.1, 0.02, false),
            "Moving the \"within\" bars of the long entry rule from 20 to 22 \
             dropped the Sharpe from 0.40 to 0.10"
        );
    }

    #[test]
    fn two_time_rules_of_one_kind_on_one_side_are_told_apart() {
        let s = json!({"entry": {"long": {"or": [
            {"within": 5, "rule": "a.x"}, {"within": 10, "rule": "b.y"}]}}});
        let names: Vec<String> = neighbours(&s).into_iter().map(|n| n.setting).collect();
        assert_eq!(
            names,
            vec![
                "entry.long.within",
                "entry.long.within",
                "entry.long.within#2",
                "entry.long.within#2"
            ]
        );
    }

    #[test]
    fn a_ranked_basket_moves_its_rebalance_spacing_but_not_its_counts() {
        let s = json!({
            "components": {"m": {"type": "Momentum", "params": {"lookback": 252}}},
            "basket": {"markets": ["A", "B", "C"], "mode": "ranked",
                "rank": {"by": "m.roc", "every_bars": 21, "long_top": 1, "short_bottom": 1}},
        });
        let moves: Vec<(String, f64)> = neighbours(&s)
            .into_iter()
            .filter(|n| n.setting.starts_with("basket"))
            .map(|n| (n.setting, n.to))
            .collect();
        assert_eq!(
            moves,
            vec![
                ("basket.every_bars".into(), 19.0),
                ("basket.every_bars".into(), 23.0)
            ]
        );
        let down = neighbours(&s)
            .into_iter()
            .find(|n| n.setting == "basket.every_bars")
            .unwrap();
        assert_eq!(down.parameters["basket"]["rank"]["every_bars"], json!(19));
        assert_eq!(down.parameters["basket"]["rank"]["long_top"], json!(1));
        assert_eq!(down.parameters["basket"]["markets"], s["basket"]["markets"]);

        let every_bar = json!({"basket": {"rank": {"every_bars": 1}}});
        let skips: Vec<Option<&str>> = neighbours(&every_bar).into_iter().map(|n| n.skip).collect();
        assert_eq!(
            skips,
            vec![Some("a ranked basket rebalances at least every bar"), None]
        );
    }

    #[test]
    fn non_numbers_and_zero_floats_are_left_alone() {
        let s = json!({
            "components": {"e": {"type": "EventWindow", "params": {
                "events": ["2026-01-01T00:00:00Z"], "start_offset_minutes": 0,
                "calendar": "fomc"}},
                "v": {"type": "Vwap", "params": {}},
                "z": {"type": "Bollinger", "params": {"period": 20, "std_dev_mult": 0.0}}},
            "stop": {"type": "FromComponent", "params": {"component": "e"}},
        });
        let settings: Vec<(String, f64)> = neighbours(&s)
            .into_iter()
            .map(|n| (n.setting, n.to))
            .collect();
        assert_eq!(
            settings,
            vec![
                ("e.start_offset_minutes".into(), -1.0),
                ("e.start_offset_minutes".into(), 1.0),
                ("z.period".into(), 18.0),
                ("z.period".into(), 22.0),
            ]
        );
    }

    #[test]
    fn a_neighbour_passes_only_when_it_keeps_half_the_sharpe_and_makes_money() {
        let rows = [
            row("worst_sharpe_retention", "gte", 0.5),
            row("worst_total_return", "gt", 0.0),
        ];
        assert!(neighbour_passes(&rows, 0.5, 0.01));
        assert!(!neighbour_passes(&rows, 0.49, 0.01));
        assert!(!neighbour_passes(&rows, 0.9, 0.0));
        // A row on some other metric doesn't judge a single neighbour.
        assert!(neighbour_passes(&[row("tested", "gte", 99.0)], 0.9, 0.1));
    }

    #[test]
    fn the_failure_names_the_setting_and_what_it_did() {
        let n = neighbours(&strategy())
            .into_iter()
            .find(|n| n.setting == "r.rsi_period" && n.to == 3.0)
            .unwrap();
        assert_eq!(
            failure_words(&n, 0.42, 0.11, 0.05, false),
            "Moving rsi period (r, RsiReversion) from 2 to 3 dropped the Sharpe from 0.42 to 0.11"
        );
        assert_eq!(
            failure_words(&n, 0.42, 0.30, -0.012, true),
            "Moving rsi period (r, RsiReversion) from 2 to 3 left it not making money (-1.20%)"
        );
    }
}
