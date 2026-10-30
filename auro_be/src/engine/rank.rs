//! Ranking across markets (cross-sectional): the rule behind FX carry
//! (Lustig, Roussanov & Verdelhan 2011) and cross-sectional momentum. On
//! each rebalance bar every market in a basket gets a score, a value one of
//! the recipe's blocks shows (`Signaler::series`, e.g. `carry.carry` or
//! `mom.roc`); the highest `long_top` are bought, the lowest `short_bottom`
//! sold, and everything else is flat until the next rebalance.
//!
//! The decision is one pure function, `targets`, so the backtest
//! (`pipeline::basket`) and a live runner can make it the same way.
//! `rebalance_slot` is the shared clock: which bar of each market counts as
//! the same moment.

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use crate::engine::types::{Direction, Granularity};

/// How a basket ranks its markets. Lives next to the market list in the
/// basket config (`strategy_configs.parameters.basket.rank`).
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct RankRule {
    /// `"<block>.<value>"`: the block's name in the recipe and the value it
    /// shows (`Signaler::series`).
    pub by: String,
    /// Bars between rebalances (21 daily bars ≈ a month).
    pub every_bars: usize,
    /// How many of the highest scores to buy.
    pub long_top: usize,
    /// How many of the lowest scores to sell short.
    pub short_bottom: usize,
}

impl RankRule {
    /// The block name and value name `by` points at.
    pub fn source(&self) -> Option<(&str, &str)> {
        self.by
            .split_once('.')
            .filter(|(block, value)| !block.is_empty() && !value.is_empty())
    }

    /// Why this rule can't rank `markets` markets, in plain words.
    pub fn check(&self, markets: usize) -> Result<(), String> {
        if self.source().is_none() {
            return Err(format!(
                "the ranking needs a block and one of its values, like \"mom.roc\", not {:?}",
                self.by
            ));
        }
        if self.every_bars == 0 {
            return Err("the ranking needs at least 1 bar between rebalances".into());
        }
        if self.long_top + self.short_bottom == 0 {
            return Err("the ranking must buy or sell at least one market".into());
        }
        if self.long_top + self.short_bottom > markets {
            return Err(format!(
                "the ranking buys {} and sells {}, more than the {} markets in the basket",
                self.long_top, self.short_bottom, markets
            ));
        }
        Ok(())
    }
}

/// What to hold after a rebalance: the `long_top` best-scoring markets
/// long, the `short_bottom` worst short, every other market flat (left out
/// of the result).
///
/// - A market without a score (its block can't compute yet, or the value
///   isn't a finite number) isn't ranked, so it's flat.
/// - Equal scores rank by market name, so the result never depends on the
///   order the scores came in. No market is both bought and sold.
/// - With fewer scored markets than `long_top + short_bottom` there's
///   nothing fair to rank: None, keep what you hold.
pub fn targets(
    scores: &[(&str, Option<f64>)],
    rule: &RankRule,
) -> Option<Vec<(String, Direction)>> {
    let mut ranked: Vec<(&str, f64)> = scores
        .iter()
        .filter_map(|(market, score)| score.filter(|s| s.is_finite()).map(|s| (*market, s)))
        .collect();
    if ranked.len() < rule.long_top + rule.short_bottom || ranked.is_empty() {
        return None;
    }
    // Best first; equal scores by name. The shorts come from the far end
    // of what the longs left, so no market is bought and sold at once.
    ranked.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(b.0)));
    let (top, rest) = ranked.split_at(rule.long_top);
    let longs = top.iter().map(|(m, _)| (m.to_string(), Direction::Long));
    let shorts = rest
        .iter()
        .rev()
        .take(rule.short_bottom)
        .map(|(m, _)| (m.to_string(), Direction::Short));
    Some(longs.chain(shorts).collect())
}

/// The moment a bar belongs to, the same for every market: bars of one
/// timeframe whose open times are within a few hours of each other share a
/// slot. OANDA opens daily bars at 17:00 New York for FX and metals but
/// 16:00 for indices, so their UTC times differ by an hour; shifting by 4
/// hours before cutting puts both in the day they trade.
pub fn rebalance_slot(time: DateTime<Utc>, granularity: Granularity) -> i64 {
    let period = match granularity {
        Granularity::D => Duration::days(1),
        Granularity::H4 => Duration::hours(4),
        Granularity::H1 => Duration::hours(1),
        Granularity::M15 => Duration::minutes(15),
        Granularity::M5 => Duration::minutes(5),
        Granularity::M1 => Duration::minutes(1),
    };
    (time + Duration::hours(4))
        .timestamp()
        .div_euclid(period.num_seconds())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn rule(long_top: usize, short_bottom: usize) -> RankRule {
        RankRule {
            by: "mom.roc".into(),
            every_bars: 21,
            long_top,
            short_bottom,
        }
    }

    fn held(t: Option<Vec<(String, Direction)>>) -> Vec<(String, Direction)> {
        t.expect("enough scores to rank")
    }

    #[test]
    fn the_best_are_bought_and_the_worst_sold() {
        let scores = [
            ("A", Some(0.05)),
            ("B", Some(-0.02)),
            ("C", Some(0.10)),
            ("D", Some(-0.08)),
            ("E", Some(0.01)),
        ];
        assert_eq!(
            held(targets(&scores, &rule(2, 1))),
            vec![
                ("C".to_string(), Direction::Long),
                ("A".to_string(), Direction::Long),
                ("D".to_string(), Direction::Short),
            ]
        );
    }

    #[test]
    fn markets_without_a_score_are_not_ranked() {
        let scores = [
            ("A", Some(0.05)),
            ("B", None),
            ("C", Some(f64::NAN)),
            ("D", Some(-0.08)),
        ];
        assert_eq!(
            held(targets(&scores, &rule(1, 1))),
            vec![
                ("A".to_string(), Direction::Long),
                ("D".to_string(), Direction::Short),
            ]
        );
    }

    #[test]
    fn too_few_scores_keep_what_you_hold() {
        let scores = [("A", Some(0.05)), ("B", None), ("C", Some(0.01))];
        assert_eq!(targets(&scores, &rule(2, 1)), None);
        assert_eq!(targets(&[], &rule(1, 0)), None);
    }

    #[test]
    fn ties_rank_by_name_whatever_the_order() {
        let a = [("B", Some(1.0)), ("A", Some(1.0)), ("C", Some(1.0))];
        let b = [("C", Some(1.0)), ("A", Some(1.0)), ("B", Some(1.0))];
        let expected = vec![
            ("A".to_string(), Direction::Long),
            ("C".to_string(), Direction::Short),
        ];
        assert_eq!(held(targets(&a, &rule(1, 1))), expected);
        assert_eq!(held(targets(&b, &rule(1, 1))), expected);
    }

    #[test]
    fn a_rule_is_checked_against_the_basket() {
        assert!(rule(3, 3).check(6).is_ok());
        assert!(rule(3, 3).check(5).unwrap_err().contains("more than the 5"));
        assert!(rule(0, 0).check(5).is_err());
        let no_value = RankRule {
            by: "mom".into(),
            ..rule(1, 1)
        };
        assert!(no_value.check(5).unwrap_err().contains("mom.roc"));
        let never = RankRule {
            every_bars: 0,
            ..rule(1, 1)
        };
        assert!(never.check(5).is_err());
    }

    #[test]
    fn fx_and_index_daily_bars_share_a_slot() {
        let fx = Utc.with_ymd_and_hms(2025, 3, 3, 22, 0, 0).unwrap();
        let index = Utc.with_ymd_and_hms(2025, 3, 3, 21, 0, 0).unwrap();
        let next = Utc.with_ymd_and_hms(2025, 3, 4, 22, 0, 0).unwrap();
        assert_eq!(
            rebalance_slot(fx, Granularity::D),
            rebalance_slot(index, Granularity::D)
        );
        assert_eq!(
            rebalance_slot(next, Granularity::D),
            rebalance_slot(fx, Granularity::D) + 1
        );
    }
}
