//! Rules cache populated by Opus and consulted on the hot path.
//!
//! Per Decision Log #23: Opus is authoritative for rules. Opus persists them to
//! the `rules` table AND pushes the full payload to Rust via HTTP. Rust holds
//! the result here in `Arc<RwLock<Rules>>` for sub-microsecond lookup during
//! `evaluate_entry`.
//!
//! This module owns the wire format and the in-memory representation only. The
//! HTTP handler that updates this lives in `api/rules.rs`. Recovery on startup
//! (reading from DB) lives in `main.rs` and is wired in a later step.
//!
//! Per Decision #18: Rust enforces, Opus configures. Rust never decides whether
//! a rule should be enabled — it only checks the boolean Opus already computed.

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::engine::types::{LiveStrategy, SignalAction, SignalReport};

/// In-memory rules cache. Single source of truth on the Rust side after a push.
///
/// Replaced atomically by `apply_payload` — partial updates are not allowed.
/// The full set of strategies' decisions arrives in one push from Opus.
#[derive(Debug, Default, Clone)]
pub struct Rules {
    /// Per-strategy decision keyed by `live_strategies.id`.
    pub by_strategy_id: HashMap<Uuid, RuleEntry>,
    /// When this snapshot was computed (set by Opus, preserved through push).
    pub computed_at: Option<DateTime<Utc>>,
}

/// Decision for one strategy. Just the result + audit string. The condition
/// (e.g. "ADX > 25") is evaluated by Opus; Rust only sees `enabled`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleEntry {
    /// May this strategy fire entry signals right now?
    pub enabled: bool,
    /// Human-readable reason for the decision (logged when an entry is gated).
    /// Example: "trending regime, ADX 32.4" or "choppy regime, TF disabled".
    pub reason: String,
}

/// Wire format Opus POSTs to `/api/rules`. Replaces the entire cache.
///
/// Designed so that adding new fields later (per-strategy params, expiry time,
/// etc.) doesn't break compatibility — Rust ignores fields it doesn't know.
#[derive(Debug, Deserialize)]
pub struct RulesPayload {
    pub rules: HashMap<Uuid, RuleEntry>,
    pub computed_at: DateTime<Utc>,
}

impl Rules {
    pub fn count(payload: &RulesPayload) -> (usize, usize) {
        let (enabled, disabled) = payload.rules.values().fold((0, 0), |(e, d), entry| {
            if entry.enabled {
                (e + 1, d)
            } else {
                (e, d + 1)
            }
        });
        (enabled, disabled)
    }
    /// Look up whether a strategy is allowed to fire. Default for an unknown
    /// strategy is **enabled** — strategies without rules behave as they did
    /// before the rules engine. This avoids accidentally disabling everything
    /// if Opus is offline at startup.
    ///
    /// The audit string in the second slot is for logging; pass
    /// `Some("rules push not yet received")` from the caller if `None`.
    pub fn decision(&self, strategy_id: &Uuid) -> (bool, Option<&str>) {
        if let Some(rule_entry) = self.by_strategy_id.get(strategy_id) {
            (rule_entry.enabled, Some(rule_entry.reason.as_str()))
        } else {
            (true, None)
        }
    }

    /// Replace the entire rules state from a fresh push.
    /// Logs the count breakdown (enabled vs disabled) for observability.
    pub fn apply_payload(&mut self, payload: RulesPayload) {
        let (enabled, disabled) = Rules::count(&payload);
        tracing::info!(
            "[RULES] applied: enabled={}, disabled={}, computed_at={}",
            enabled,
            disabled,
            payload.computed_at
        );
        self.by_strategy_id = payload.rules;
        self.computed_at = Some(payload.computed_at);
    }

    /// Build a Rules cache from raw DB rows queried out of the `rules` table.
    /// `reason` is nullable in DB; null becomes a placeholder string here so
    /// the in-memory `RuleEntry.reason: String` stays non-optional.
    /// The cache's `computed_at` is the max across all rows (most recent push).
    pub fn from_db_rows(rows: Vec<(Uuid, bool, Option<String>, DateTime<Utc>)>) -> Self {
        let mut by_strategy_id = HashMap::with_capacity(rows.len());
        let mut latest: Option<DateTime<Utc>> = None;

        for (id, enabled, reason, computed_at) in rows {
            by_strategy_id.insert(
                id,
                RuleEntry {
                    enabled,
                    reason: reason.unwrap_or_else(|| "(no reason recorded)".to_string()),
                },
            );
            if latest.map_or(true, |t| computed_at > t) {
                latest = Some(computed_at);
            }
        }

        Self {
            by_strategy_id,
            computed_at: latest,
        }
    }
}

/// Returns `None` if the strategy may fire an entry under current rules; returns
/// `Some(SignalReport)` describing the gate if blocked.
///
/// Used at every `execute_entry` call site in `evaluate_entry`. Mirrors the
/// existing `position_already_open` rejection pattern — callers short-circuit
/// with `return Ok(Some(report))` when this returns `Some`.
///
/// The same helper handles both strategy types because the policy is keyed by
/// `live_strategy_id`, not by strategy_type. Per Decision #18, type-specific
/// gating already happened in Opus's policy clauses.
pub fn entry_gate_report(
    rules: &Rules,
    strategy: &LiveStrategy,
    current_price: f64,
) -> Option<SignalReport> {
    let (enabled, reason) = rules.decision(&strategy.id);
    if enabled {
        return None;
    }

    let reason_str = reason.unwrap_or("no rule reason recorded").to_string();

    tracing::info!(
        "[GATED] {} {} ({}) entry suppressed by rule: {}",
        strategy.instrument,
        strategy.granularity,
        strategy.strategy_type,
        reason_str
    );

    Some(SignalReport {
        strategy_id: strategy.id,
        strategy_type: strategy.strategy_type.clone(),
        instrument: strategy.instrument.clone(),
        granularity: strategy.granularity,
        action: SignalAction::EntryRejected,
        price: current_price,
        reason: format!("rule_disabled: {}", reason_str),
        oanda_trade_id: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(enabled: bool, reason: &str) -> RuleEntry {
        RuleEntry {
            enabled,
            reason: reason.to_string(),
        }
    }

    #[test]
    fn unknown_strategy_defaults_to_enabled() {
        let rules = Rules::default();
        let unknown_id = Uuid::new_v4();
        let (enabled, reason) = rules.decision(&unknown_id);
        assert!(enabled, "unknown strategy should default to enabled");
        assert!(reason.is_none(), "no reason when no rule applies");
    }

    #[test]
    fn known_disabled_strategy_returns_reason() {
        let mut rules = Rules::default();
        let id = Uuid::new_v4();
        rules
            .by_strategy_id
            .insert(id, entry(false, "ADX 18 (choppy)"));
        let (enabled, reason) = rules.decision(&id);
        assert!(!enabled);
        assert_eq!(reason, Some("ADX 18 (choppy)"));
    }

    #[test]
    fn from_db_rows_handles_nulls_and_picks_latest_computed_at() {
        let id1 = Uuid::new_v4();
        let id2 = Uuid::new_v4();
        let earlier = Utc::now() - chrono::Duration::hours(1);
        let later = Utc::now();

        let rows = vec![
            (id1, true, Some("trending".to_string()), earlier),
            (id2, false, None, later), // null reason, more recent
        ];

        let rules = Rules::from_db_rows(rows);

        assert_eq!(rules.by_strategy_id.len(), 2);
        assert_eq!(rules.decision(&id1), (true, Some("trending")));
        assert_eq!(rules.decision(&id2), (false, Some("(no reason recorded)")));
        assert_eq!(rules.computed_at, Some(later));
    }

    #[test]
    fn from_db_rows_empty_yields_empty_cache() {
        let rules = Rules::from_db_rows(vec![]);
        assert_eq!(rules.by_strategy_id.len(), 0);
        assert!(rules.computed_at.is_none());
    }

    #[test]
    fn apply_payload_replaces_cache_atomically() {
        let mut rules = Rules::default();
        let old_id = Uuid::new_v4();
        rules.by_strategy_id.insert(old_id, entry(true, "old"));

        let new_id = Uuid::new_v4();
        let mut new_map = HashMap::new();
        new_map.insert(new_id, entry(false, "new"));

        let payload = RulesPayload {
            rules: new_map,
            computed_at: Utc::now(),
        };
        rules.apply_payload(payload);

        // Old entry must be gone, new entry present, computed_at updated.
        assert!(rules.decision(&old_id).0); // old defaults to enabled (not in map)
        assert!(!rules.decision(&new_id).0);
        assert!(rules.computed_at.is_some());
    }
}
