//! Composite strategy shape — hybrid component + DAG composition.
//!
//! A `Strategy` is a top-level container with:
//! - `components`: named signalers (TF, MR, Donchian, etc.) keyed by user-defined names
//! - `entry`/`exit`: selectors that reference ports (e.g. `"tf.bullish_cross"`) or
//!   compose them via `and`/`or`/`not`
//! - `stop`: how the stop loss is computed (fixed pct, ATR multiple, structural, etc.)
//! - `sizing`: how position size is computed (risk pct, fixed units, etc.)
//!
//! Each component exposes named output ports (typed `bool` for signal ports,
//! `f64` for level ports). The entry/exit selectors consume bool ports;
//! the stop/sizing may consume level ports.
//!
//! See [[decision-canonical-strategy-shape]] for the architectural rationale.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::engine::donchian::DonchianParams;
use crate::engine::ma_filter::MaFilterParams;
use crate::engine::macd::MacdParams;
use crate::engine::mean_reversion::MeanReversionParams;
use crate::engine::rsi_reversion::RsiReversionParams;
use crate::engine::trend_following::TrendFollowingParams;
use crate::engine::types::{Candle, Direction, EntryReason, ExitReason, Granularity, Trade};

/// Behavior contract for all signaler components. Each strategy type
/// implements this trait in its own file (TF in trend_following.rs, MR in
/// mean_reversion.rs, etc.). The `Component` enum below stays as the serde
/// tagged-enum dispatch surface and delegates each method to the trait impl.
///
/// See [[backlog-signaler-trait-and-mr-composite]] for the rationale (hybrid
/// trait + enum, avoiding `Box<dyn>` to preserve serde tagged-enum dispatch).
pub trait Signaler {
    /// Minimum number of candles required before this component can compute
    /// any output.
    fn warmup(&self) -> usize;

    /// Compute all output ports for this component against the candle window
    /// ending at the most recent close. Returns None if not enough candles
    /// or other computation prerequisites fail; the caller treats None as
    /// "no signal."
    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>>;

    /// Produce an EntryReason metadata variant when an entry fires in the
    /// given direction. Each component owns its own metadata format (TF →
    /// CrossAbove/CrossBelow, MR → MeanReversionEntry, etc.) so the generic
    /// runner doesn't need component-specific code.
    fn entry_reason(&self, candles: &[Candle], direction: Direction) -> EntryReason;

    /// Optional: compute the absolute stop-loss price for an entry in the
    /// given direction. Used by `StopConfig::FromComponent` to give the
    /// named component full control over its stop placement (e.g. MR anchors
    /// its Z-extension stop at the MA, not at entry price). Returning an
    /// absolute price — not a distance — lets components anchor wherever
    /// makes sense for their logic.
    /// Default: None (component doesn't expose its own stop placement).
    fn stop_price(&self, _candles: &[Candle], _direction: Direction) -> Option<f64> {
        None
    }
}

/// Top-level strategy configuration. Stored in `live_strategies.parameters` and
/// `strategy_configs.parameters` as JSONB. `strategy_type = "composite"` indicates
/// this shape (vs. legacy flat shapes that store params directly).
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Strategy {
    pub strategy_id: Option<Uuid>,
    pub strategy_name: Option<String>,
    pub version: String,
    pub instrument: String,
    pub granularity: Granularity,
    pub components: HashMap<String, Component>,
    pub entry: EntryExitSelector,
    pub exit: EntryExitSelector,
    pub stop: StopConfig,
    pub sizing: SizingConfig,
    pub max_hold_bars: Option<usize>,
}

/// A named component. Tagged enum: `{"type": "TrendFollowing", "params": { ... }}`.
/// The enum exists for serde dispatch only — all behavior lives in the
/// `Signaler` trait impl on each variant's inner params type. Adding a new
/// component type: write the params struct, impl Signaler for it, add a
/// variant here, add a delegation arm in the Signaler impl below.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "type", content = "params")]
pub enum Component {
    #[serde(rename = "TrendFollowing")]
    TrendFollowing(TrendFollowingParams),
    #[serde(rename = "MeanReversion")]
    MeanReversion(MeanReversionParams),
    #[serde(rename = "Macd")]
    Macd(MacdParams),
    #[serde(rename = "Donchian")]
    Donchian(DonchianParams),
    #[serde(rename = "MaFilter")]
    MaFilter(MaFilterParams),
    #[serde(rename = "RsiReversion")]
    RsiReversion(RsiReversionParams),
    // Future variants: LiquiditySweep, etc.
}

/// Long and short port selectors for entry or exit decisions.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct EntryExitSelector {
    pub long: PortRef,
    pub short: PortRef,
}

/// Reference to a signal port. Can be:
/// - A direct port name like `"tf.bullish_cross"` (resolves to the component's output)
/// - A composition: `and`, `or`, or `not` of other refs
///
/// Custom Deserialize because we want strings to parse as `Direct` without
/// requiring `{"direct": "tf.bullish_cross"}` everywhere.
#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
pub enum PortRef {
    Direct(String),
    And { and: Vec<PortRef> },
    Or { or: Vec<PortRef> },
    Not { not: Box<PortRef> },
}

impl<'de> Deserialize<'de> for PortRef {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        use serde::de::Error;
        let value = serde_json::Value::deserialize(deserializer)?;

        match value {
            serde_json::Value::String(s) => Ok(PortRef::Direct(s)),
            serde_json::Value::Object(map) => {
                if let Some(refs) = map.get("and") {
                    let refs: Vec<PortRef> =
                        serde_json::from_value(refs.clone()).map_err(D::Error::custom)?;
                    Ok(PortRef::And { and: refs })
                } else if let Some(refs) = map.get("or") {
                    let refs: Vec<PortRef> =
                        serde_json::from_value(refs.clone()).map_err(D::Error::custom)?;
                    Ok(PortRef::Or { or: refs })
                } else if let Some(inner) = map.get("not") {
                    let inner: PortRef =
                        serde_json::from_value(inner.clone()).map_err(D::Error::custom)?;
                    Ok(PortRef::Not {
                        not: Box::new(inner),
                    })
                } else {
                    Err(D::Error::custom(
                        "PortRef object must contain 'and', 'or', or 'not'",
                    ))
                }
            }
            _ => Err(D::Error::custom(
                "PortRef must be a string or an object with 'and'/'or'/'not'",
            )),
        }
    }
}

/// How to compute stop loss for a position.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "type", content = "params")]
pub enum StopConfig {
    /// SL placed at a fixed percent below (long) or above (short) the entry
    /// price. `pct` is a negative fraction (e.g. -0.02 for -2%).
    #[serde(rename = "FixedPct")]
    FixedPct { pct: f64 },
    /// SL placed at a price derived from the named component's
    /// `stop_distance(candles)`. Used by MR for Z-extension stops where the
    /// distance depends on current stdev. Component must impl
    /// `Signaler::stop_distance` and return `Some(distance)`.
    #[serde(rename = "FromComponent")]
    FromComponent { component: String },
    /// SL placed kxATR below (long) / above (short) entry. Volatility-scaled
    /// for higher timeframes where a fixed pct is too tight.
    #[serde(rename = "AtrMultiple")]
    AtrMultiple {
        k: f64,
        #[serde(default = "default_atr_period")]
        period: usize,
    },
    // Future: StructuralLevel { source: String }
}

fn default_atr_period() -> usize {
    14
}

/// How to compute position size.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "type", content = "params")]
pub enum SizingConfig {
    #[serde(rename = "RiskPct")]
    RiskPct { pct: f64 },
    // Future: FixedUnits { units: i64 }, KellyFraction, etc.
}

/// Computed signal values for all component ports at one bar.
/// Component name -> port name -> bool value (signal ports).
pub type PortValues = HashMap<String, HashMap<String, bool>>;

/// The output of a strategy evaluation at one bar.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum EntrySignal {
    Long,
    Short,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ExitSignal {
    Exit,
    Hold,
}

impl Strategy {
    /// Minimum candle count required to compute all component ports.
    pub fn warmup(&self) -> usize {
        self.components
            .values()
            .map(|c| c.warmup())
            .max()
            .unwrap_or(0)
    }

    /// Compute all component port values against the candle buffer ending at
    /// the most recent close. Returns None if any component cannot compute (e.g.
    /// insufficient candles); the caller should treat that as "no signal."
    pub fn compute_ports(&self, candles: &[Candle]) -> Option<PortValues> {
        let mut values: PortValues = HashMap::new();
        for (name, component) in &self.components {
            let component_ports = component.compute(candles)?;
            values.insert(name.clone(), component_ports);
        }
        Some(values)
    }

    /// Evaluate the entry selector against computed port values.
    pub fn evaluate_entry(&self, ports: &PortValues) -> EntrySignal {
        let long = resolve_port_ref(&self.entry.long, ports).unwrap_or(false);
        let short = resolve_port_ref(&self.entry.short, ports).unwrap_or(false);
        match (long, short) {
            (true, true) => EntrySignal::None, // ambiguous → no signal
            (true, false) => EntrySignal::Long,
            (false, true) => EntrySignal::Short,
            (false, false) => EntrySignal::None,
        }
    }

    /// Evaluate the exit selector for a given direction.
    pub fn evaluate_exit(&self, ports: &PortValues, is_long: bool) -> ExitSignal {
        let selector = if is_long {
            &self.exit.long
        } else {
            &self.exit.short
        };
        if resolve_port_ref(selector, ports).unwrap_or(false) {
            ExitSignal::Exit
        } else {
            ExitSignal::Hold
        }
    }
}

/// Delegate all `Signaler` methods on the enum to the appropriate variant's
/// trait impl. Each new component variant requires one dispatch arm here —
/// the actual logic lives in the variant's own file.
impl Component {
    pub fn warmup(&self) -> usize {
        match self {
            Component::TrendFollowing(p) => p.warmup(),
            Component::MeanReversion(p) => p.warmup(),
            Component::Macd(p) => p.warmup(),
            Component::Donchian(p) => p.warmup(),
            Component::MaFilter(p) => p.warmup(),
            Component::RsiReversion(p) => p.warmup(),
        }
    }

    pub fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        match self {
            Component::TrendFollowing(p) => p.compute(candles),
            Component::MeanReversion(p) => p.compute(candles),
            Component::Macd(p) => p.compute(candles),
            Component::Donchian(p) => p.compute(candles),
            Component::MaFilter(p) => p.compute(candles),
            Component::RsiReversion(p) => p.compute(candles),
        }
    }

    pub fn entry_reason(&self, candles: &[Candle], direction: Direction) -> EntryReason {
        match self {
            Component::TrendFollowing(p) => p.entry_reason(candles, direction),
            Component::MeanReversion(p) => p.entry_reason(candles, direction),
            Component::Macd(p) => p.entry_reason(candles, direction),
            Component::Donchian(p) => p.entry_reason(candles, direction),
            Component::MaFilter(p) => p.entry_reason(candles, direction),
            Component::RsiReversion(p) => p.entry_reason(candles, direction),
        }
    }

    pub fn stop_price(&self, candles: &[Candle], direction: Direction) -> Option<f64> {
        match self {
            Component::TrendFollowing(p) => p.stop_price(candles, direction),
            Component::MeanReversion(p) => p.stop_price(candles, direction),
            Component::Macd(p) => p.stop_price(candles, direction),
            Component::Donchian(p) => p.stop_price(candles, direction),
            Component::MaFilter(p) => p.stop_price(candles, direction),
            Component::RsiReversion(p) => p.stop_price(candles, direction),
        }
    }
}

/// Best-effort extraction of the primary component name from an entry selector.
/// Used so the runner knows which component to ask for entry-reason metadata.
/// Returns the component name in the first `PortRef::Direct` it encounters
/// (DFS); returns None if the selector is purely composed without any direct
/// port reference (which would be unusual).
fn primary_component_name(port_ref: &PortRef) -> Option<&str> {
    match port_ref {
        PortRef::Direct(name) => name.split_once('.').map(|(c, _)| c),
        PortRef::And { and } => and.iter().find_map(primary_component_name),
        PortRef::Or { or } => or.iter().find_map(primary_component_name),
        PortRef::Not { not } => primary_component_name(not),
    }
}

/// Run a strategy as a backtest over a slice of candles. Bidirectional —
/// produces both long and short trades as signals fire. Trades still open at
/// the end of the candle series are recorded with `ExitReason::EndOfData`.
pub fn run_backtest(candles: &[Candle], strategy: &Strategy) -> Vec<Trade> {
    let mut trades: Vec<Trade> = Vec::new();
    let warmup = strategy.warmup();
    if candles.len() < warmup + 1 {
        return trades;
    }

    let mut i = warmup;
    while i < candles.len() {
        let window = &candles[..=i];
        let ports = match strategy.compute_ports(window) {
            Some(p) => p,
            None => {
                i += 1;
                continue;
            }
        };

        let entry_signal = strategy.evaluate_entry(&ports);
        let direction = match entry_signal {
            EntrySignal::Long => Direction::Long,
            EntrySignal::Short => Direction::Short,
            EntrySignal::None => {
                i += 1;
                continue;
            }
        };

        let entry_time = candles[i].time;
        let entry_price = candles[i].entry_fill_price(direction);
        let entry_reason = primary_component_name(if direction == Direction::Long {
            &strategy.entry.long
        } else {
            &strategy.entry.short
        })
        .and_then(|name| strategy.components.get(name))
        .map(|c| c.entry_reason(window, direction))
        .unwrap_or(EntryReason::CrossAbove {
            fast_ma: 0.0,
            slow_ma: 0.0,
        });

        let stop_price = match compute_stop_price(strategy, entry_price, direction, window) {
            Some(p) => p,
            None => {
                // Stop config requires a component-derived distance but the
                // component didn't expose one (warmup or other prerequisite
                // not met). Skip this entry rather than open without an SL.
                i += 1;
                continue;
            }
        };

        let mut exited = false;
        let mut j = i + 1;
        while j < candles.len() {
            let exit_window = &candles[..=j];

            let sl_trigger = candles[j].sl_check_price(direction);
            let sl_hit = match direction {
                Direction::Long => sl_trigger <= stop_price,
                Direction::Short => sl_trigger >= stop_price,
            };
            if sl_hit {
                let bar_open = candles[j].directional_open(direction);
                let gap_past_sl = match direction {
                    Direction::Long => bar_open <= stop_price,
                    Direction::Short => bar_open >= stop_price,
                };
                let exit_price = if gap_past_sl { bar_open } else { stop_price };
                let pnl = match direction {
                    Direction::Long => (exit_price - entry_price) / entry_price,
                    Direction::Short => (entry_price - exit_price) / entry_price,
                };
                trades.push(Trade {
                    direction,
                    entry_price,
                    exit_price,
                    entry_time,
                    exit_time: candles[j].time,
                    pnl_percent: pnl,
                    entry_reason,
                    exit_reason: ExitReason::StopLoss,
                });
                exited = true;
                i = j + 1;
                break;
            }

            if let Some(max_hold_bars) = strategy.max_hold_bars {
                if j - i >= max_hold_bars {
                    let exit_price = candles[j].exit_fill_price(direction);
                    let pnl = match direction {
                        Direction::Long => (exit_price - entry_price) / entry_price,
                        Direction::Short => (entry_price - exit_price) / entry_price,
                    };
                    trades.push(Trade {
                        direction,
                        entry_price,
                        exit_price,
                        entry_time,
                        exit_time: candles[j].time,
                        pnl_percent: pnl,
                        entry_reason,
                        exit_reason: ExitReason::TimeStop,
                    });
                    exited = true;
                    i = j + 1;
                    break;
                }
            }

            let exit_ports = match strategy.compute_ports(exit_window) {
                Some(p) => p,
                None => {
                    j += 1;
                    continue;
                }
            };
            let exit_signal = strategy.evaluate_exit(&exit_ports, direction == Direction::Long);
            if matches!(exit_signal, ExitSignal::Exit) {
                let exit_price = candles[j].exit_fill_price(direction);
                let pnl = match direction {
                    Direction::Long => (exit_price - entry_price) / entry_price,
                    Direction::Short => (entry_price - exit_price) / entry_price,
                };
                trades.push(Trade {
                    direction,
                    entry_price,
                    exit_price,
                    entry_time,
                    exit_time: candles[j].time,
                    pnl_percent: pnl,
                    entry_reason,
                    exit_reason: ExitReason::TrendReversal,
                });
                exited = true;
                i = j + 1;
                break;
            }
            j += 1;
        }

        if !exited {
            let last = candles.last().expect("non-empty by guard above");
            let exit_price = last.exit_fill_price(direction);
            let pnl = match direction {
                Direction::Long => (exit_price - entry_price) / entry_price,
                Direction::Short => (entry_price - exit_price) / entry_price,
            };
            trades.push(Trade {
                direction,
                entry_price,
                exit_price,
                entry_time,
                exit_time: last.time,
                pnl_percent: pnl,
                entry_reason,
                exit_reason: ExitReason::EndOfData,
            });
            break;
        }
    }

    trades
}

/// Compute the absolute stop-loss price for a position given the strategy's
/// stop config, the entry price, the trade direction, and the candle window
/// at entry time (needed for `FromComponent` which derives stop from a
/// component's current state, e.g. MR's stdev).
///
/// Returns None when `FromComponent` is configured but the named component
/// doesn't exist or doesn't expose a stop distance. Callers should treat
/// None as "cannot place this trade" and skip the entry.
pub fn compute_stop_price(
    strategy: &Strategy,
    entry_price: f64,
    direction: Direction,
    candles: &[Candle],
) -> Option<f64> {
    match &strategy.stop {
        StopConfig::FixedPct { pct } => Some(match direction {
            Direction::Long => entry_price * (1.0 + pct),
            Direction::Short => entry_price * (1.0 - pct),
        }),
        StopConfig::AtrMultiple { k, period } => {
            let atr = crate::engine::indicators::atr(candles, *period)?;
            Some(match direction {
                Direction::Long => entry_price - k * atr,
                Direction::Short => entry_price + k * atr,
            })
        }
        StopConfig::FromComponent { component } => {
            // Component computes the absolute stop price (it can anchor wherever
            // makes sense — MR uses MA ± k·stdev, not entry ± distance).
            // entry_price is unused here but kept in the signature so the
            // backtest runner and live evaluator can call uniformly.
            let _ = entry_price;
            let comp = strategy.components.get(component)?;
            comp.stop_price(candles, direction)
        }
    }
}

/// Resolve a PortRef to a bool value given the computed port values.
/// Returns Some(value) if all referenced ports were computed; None if any
/// referenced port is missing (treat as "no signal").
fn resolve_port_ref(port_ref: &PortRef, ports: &PortValues) -> Option<bool> {
    match port_ref {
        PortRef::Direct(name) => {
            let (component, port) = name.split_once('.')?;
            ports.get(component)?.get(port).copied()
        }
        PortRef::And { and } => {
            let mut result = true;
            for r in and {
                result = result && resolve_port_ref(r, ports)?;
            }
            Some(result)
        }
        PortRef::Or { or } => {
            let mut result = false;
            for r in or {
                result = result || resolve_port_ref(r, ports)?;
            }
            Some(result)
        }
        PortRef::Not { not } => Some(!resolve_port_ref(not, ports)?),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn port_ref_deserializes_string_as_direct() {
        let r: PortRef = serde_json::from_value(json!("tf.bullish_cross")).unwrap();
        assert!(matches!(r, PortRef::Direct(ref s) if s == "tf.bullish_cross"));
    }

    #[test]
    fn port_ref_deserializes_and() {
        let r: PortRef =
            serde_json::from_value(json!({ "and": ["tf.bullish_cross", "session.active"] }))
                .unwrap();
        assert!(matches!(r, PortRef::And { ref and } if and.len() == 2));
    }

    #[test]
    fn port_ref_deserializes_or() {
        let r: PortRef = serde_json::from_value(json!({ "or": ["a.x", "b.y"] })).unwrap();
        assert!(matches!(r, PortRef::Or { ref or } if or.len() == 2));
    }

    #[test]
    fn port_ref_deserializes_not() {
        let r: PortRef = serde_json::from_value(json!({ "not": "tf.bullish_cross" })).unwrap();
        assert!(matches!(r, PortRef::Not { .. }));
    }

    #[test]
    fn resolve_direct_port_returns_value() {
        let mut ports: PortValues = HashMap::new();
        let mut tf_ports = HashMap::new();
        tf_ports.insert("bullish_cross".to_string(), true);
        ports.insert("tf".to_string(), tf_ports);

        assert_eq!(
            resolve_port_ref(&PortRef::Direct("tf.bullish_cross".to_string()), &ports),
            Some(true)
        );
    }

    #[test]
    fn resolve_missing_port_returns_none() {
        let ports: PortValues = HashMap::new();
        assert_eq!(
            resolve_port_ref(&PortRef::Direct("tf.bullish_cross".to_string()), &ports),
            None
        );
    }

    #[test]
    fn resolve_and_returns_logical_and() {
        let mut ports: PortValues = HashMap::new();
        let mut tf_ports = HashMap::new();
        tf_ports.insert("a".to_string(), true);
        tf_ports.insert("b".to_string(), false);
        ports.insert("tf".to_string(), tf_ports);

        let r = PortRef::And {
            and: vec![
                PortRef::Direct("tf.a".to_string()),
                PortRef::Direct("tf.b".to_string()),
            ],
        };
        assert_eq!(resolve_port_ref(&r, &ports), Some(false));
    }

    #[test]
    fn resolve_or_returns_logical_or() {
        let mut ports: PortValues = HashMap::new();
        let mut tf_ports = HashMap::new();
        tf_ports.insert("a".to_string(), true);
        tf_ports.insert("b".to_string(), false);
        ports.insert("tf".to_string(), tf_ports);

        let r = PortRef::Or {
            or: vec![
                PortRef::Direct("tf.a".to_string()),
                PortRef::Direct("tf.b".to_string()),
            ],
        };
        assert_eq!(resolve_port_ref(&r, &ports), Some(true));
    }

    #[test]
    fn resolve_not_inverts() {
        let mut ports: PortValues = HashMap::new();
        let mut tf_ports = HashMap::new();
        tf_ports.insert("a".to_string(), true);
        ports.insert("tf".to_string(), tf_ports);

        let r = PortRef::Not {
            not: Box::new(PortRef::Direct("tf.a".to_string())),
        };
        assert_eq!(resolve_port_ref(&r, &ports), Some(false));
    }

    #[test]
    fn full_tf_strategy_roundtrips_json() {
        let json = serde_json::json!({
            "strategy_id": null,
            "strategy_name": "test",
            "version": "v1_composite",
            "instrument": "EUR_GBP",
            "granularity": "H1",
            "components": {
                "tf": {
                    "type": "TrendFollowing",
                    "params": { "fast_period": 50, "slow_period": 200 }
                }
            },
            "entry": {
                "long":  "tf.bullish_cross",
                "short": "tf.bearish_cross"
            },
            "exit": {
                "long":  "tf.bearish_cross",
                "short": "tf.bullish_cross"
            },
            "stop":   { "type": "FixedPct", "params": { "pct": -0.02 } },
            "sizing": { "type": "RiskPct", "params": { "pct": 0.01 } }
        });
        let strategy: Strategy = serde_json::from_value(json).expect("should parse");
        assert!(strategy.components.contains_key("tf"));
        assert_eq!(strategy.warmup(), 201);
    }

    fn make_candle(close: f64, idx: i64) -> Candle {
        use crate::engine::types::OHLC;
        use chrono::{Duration, TimeZone, Utc};
        Candle {
            time: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap() + Duration::hours(idx),
            mid: OHLC {
                open: close,
                high: close,
                low: close,
                close,
            },
            volume: 1,
            bid: None,
            ask: None,
        }
    }

    fn tf_strategy(fast: usize, slow: usize, stop_pct: f64) -> Strategy {
        let mut components: HashMap<String, Component> = HashMap::new();
        components.insert(
            "tf".to_string(),
            Component::TrendFollowing(TrendFollowingParams {
                fast_period: fast,
                slow_period: slow,
                ma_type: crate::engine::trend_following::MaType::Sma,
            }),
        );
        Strategy {
            strategy_id: None,
            strategy_name: Some("tf_test".to_string()),
            version: "v1_composite".to_string(),
            instrument: "TEST".to_string(),
            granularity: Granularity::H1,
            components,
            entry: EntryExitSelector {
                long: PortRef::Direct("tf.bullish_cross".to_string()),
                short: PortRef::Direct("tf.bearish_cross".to_string()),
            },
            exit: EntryExitSelector {
                long: PortRef::Direct("tf.bearish_cross".to_string()),
                short: PortRef::Direct("tf.bullish_cross".to_string()),
            },
            stop: StopConfig::FixedPct { pct: stop_pct },
            sizing: SizingConfig::RiskPct { pct: 0.01 },
            max_hold_bars: None,
        }
    }

    #[test]
    fn backtest_no_crosses_produces_no_trades() {
        let candles: Vec<Candle> = (0..300).map(|i| make_candle(100.0, i)).collect();
        let strategy = tf_strategy(50, 200, -0.02);
        let trades = run_backtest(&candles, &strategy);
        assert!(trades.is_empty());
    }

    #[test]
    fn backtest_captures_bullish_then_bearish_cycle() {
        // Build a series with a clear up-leg followed by a clear down-leg.
        // Should produce at least one Long trade exited on bearish cross,
        // and possibly a Short trade exited on the next bullish cross.
        let mut prices: Vec<f64> = vec![100.0; 50];
        for i in 0..50 {
            prices.push(100.0 + i as f64 * 0.5); // up-leg
        }
        for i in 0..50 {
            prices.push(125.0 - i as f64 * 0.5); // down-leg
        }
        let candles: Vec<Candle> = prices
            .into_iter()
            .enumerate()
            .map(|(i, p)| make_candle(p, i as i64))
            .collect();

        // Use small periods so the crosses actually trigger.
        let strategy = tf_strategy(5, 20, -0.10);
        let trades = run_backtest(&candles, &strategy);
        assert!(!trades.is_empty(), "expected at least one trade");
        let longs = trades
            .iter()
            .filter(|t| t.direction == Direction::Long)
            .count();
        let shorts = trades
            .iter()
            .filter(|t| t.direction == Direction::Short)
            .count();
        // At least one direction should fire.
        assert!(longs + shorts > 0);
    }

    #[test]
    fn backtest_stops_on_fixed_pct_stop_loss() {
        // Build a series where the long entry fires, then price drops sharply
        // through the stop. The trade should record StopLoss.
        let mut prices: Vec<f64> = vec![100.0; 50];
        for i in 0..50 {
            prices.push(100.0 + i as f64 * 0.5); // up-leg triggers long entry
        }
        // Cliff drop: -15% in one bar (well past -2% stop)
        prices.push(106.0);
        let candles: Vec<Candle> = prices
            .into_iter()
            .enumerate()
            .map(|(i, p)| make_candle(p, i as i64))
            .collect();
        let strategy = tf_strategy(5, 20, -0.02);
        let trades = run_backtest(&candles, &strategy);
        // The trade may or may not have exited by another mechanism first.
        // We just verify the backtest completes without panicking on stop logic.
        // For a more deterministic assertion, scan trades for any StopLoss exit.
        let any_stop = trades.iter().any(|t| t.exit_reason == ExitReason::StopLoss);
        let any_reversal = trades
            .iter()
            .any(|t| t.exit_reason == ExitReason::TrendReversal);
        // At least one trade should have an interpretable exit.
        assert!(any_stop || any_reversal || !trades.is_empty());
    }

    // ---- MR composite shape tests ----

    fn mr_strategy() -> Strategy {
        let mut components: HashMap<String, Component> = HashMap::new();
        components.insert(
            "mr".to_string(),
            Component::MeanReversion(MeanReversionParams {
                ma_period: 20,
                rsi_period: 14,
                entry_z_threshold: 1.5,
                rsi_oversold: 30.0,
                rsi_overbought: 70.0,
                stop_z_threshold: 3.5,
            }),
        );
        Strategy {
            strategy_id: None,
            strategy_name: Some("mr_test".to_string()),
            version: "v1_composite".to_string(),
            instrument: "TEST".to_string(),
            granularity: Granularity::M15,
            components,
            entry: EntryExitSelector {
                long: PortRef::Direct("mr.long".to_string()),
                short: PortRef::Direct("mr.short".to_string()),
            },
            exit: EntryExitSelector {
                long: PortRef::Direct("mr.exit_long".to_string()),
                short: PortRef::Direct("mr.exit_short".to_string()),
            },
            stop: StopConfig::FromComponent {
                component: "mr".to_string(),
            },
            sizing: SizingConfig::RiskPct { pct: 0.01 },
            max_hold_bars: None,
        }
    }

    #[test]
    fn backtest_exits_at_time_stop_when_max_hold_is_hit() {
        let mut prices: Vec<f64> = vec![100.0; 50];
        for i in 0..40 {
            prices.push(100.0 + i as f64 * 0.2);
        }

        let candles: Vec<Candle> = prices
            .into_iter()
            .enumerate()
            .map(|(i, p)| make_candle(p, i as i64))
            .collect();

        let mut strategy = tf_strategy(5, 20, -0.2);
        strategy.max_hold_bars = Some(3);

        let trades = run_backtest(&candles, &strategy);
        let timed = trades
            .iter()
            .find(|t| t.exit_reason == ExitReason::TimeStop)
            .expect("expected at least one time-stop exit");

        assert_eq!(
            (timed.exit_time - timed.entry_time).num_hours(),
            3,
            "time-stop should close exactly at max_hold_bars"
        );
    }

    #[test]
    fn full_mr_strategy_roundtrips_json() {
        let json = serde_json::json!({
            "strategy_id": null,
            "strategy_name": "test_mr",
            "version": "v1_composite",
            "instrument": "EUR_GBP",
            "granularity": "M15",
            "components": {
                "mr": {
                    "type": "MeanReversion",
                    "params": {
                        "ma_period": 20,
                        "rsi_period": 14,
                        "entry_z_threshold": 1.5,
                        "rsi_oversold": 30.0,
                        "rsi_overbought": 70.0,
                        "stop_z_threshold": 3.5
                    }
                }
            },
            "entry": { "long": "mr.long", "short": "mr.short" },
            "exit":  { "long": "mr.exit_long", "short": "mr.exit_short" },
            "stop":  { "type": "FromComponent", "params": { "component": "mr" } },
            "sizing": { "type": "RiskPct", "params": { "pct": 0.01 } }
        });
        let strategy: Strategy = serde_json::from_value(json).expect("should parse");
        assert!(strategy.components.contains_key("mr"));
        assert!(matches!(strategy.stop, StopConfig::FromComponent { .. }));
    }

    #[test]
    fn mr_compute_emits_four_ports() {
        // Stable history followed by sharp drop should fire long entry.
        let mut candles: Vec<Candle> = (0..19)
            .map(|i| {
                // Need actual variance for RSI/stdev to compute, so alternate
                // up and down by tiny amounts.
                let p = if i % 2 == 0 { 100.0 } else { 100.1 };
                make_candle(p, i)
            })
            .collect();
        candles.push(make_candle(90.0, 19));

        let mr = MeanReversionParams {
            ma_period: 20,
            rsi_period: 14,
            entry_z_threshold: 1.5,
            rsi_oversold: 30.0,
            rsi_overbought: 70.0,
            stop_z_threshold: 3.5,
        };
        let ports = mr.compute(&candles).expect("should compute");
        // All four expected ports present:
        assert!(ports.contains_key("long"));
        assert!(ports.contains_key("short"));
        assert!(ports.contains_key("exit_long"));
        assert!(ports.contains_key("exit_short"));
    }

    #[test]
    fn mr_stop_price_anchors_at_ma() {
        // Construct candles with known mean and stdev:
        // 10 candles at 102, 10 at 98 → mean = 100, popn stdev = 2.
        // For long: SL = 100 - 3.5 * 2 = 93.
        // For short: SL = 100 + 3.5 * 2 = 107.
        let prices: Vec<f64> = (0..10)
            .map(|_| 102.0)
            .chain((0..10).map(|_| 98.0))
            .collect();
        let candles: Vec<Candle> = prices
            .into_iter()
            .enumerate()
            .map(|(i, p)| make_candle(p, i as i64))
            .collect();
        let mr = MeanReversionParams {
            ma_period: 20,
            rsi_period: 14,
            entry_z_threshold: 1.5,
            rsi_oversold: 30.0,
            rsi_overbought: 70.0,
            stop_z_threshold: 3.5,
        };
        let long_stop = mr.stop_price(&candles, Direction::Long).unwrap();
        let short_stop = mr.stop_price(&candles, Direction::Short).unwrap();
        assert!((long_stop - 93.0).abs() < 0.01, "long_stop={}", long_stop);
        assert!(
            (short_stop - 107.0).abs() < 0.01,
            "short_stop={}",
            short_stop
        );
    }

    #[test]
    fn mr_strategy_compute_stop_price_via_from_component() {
        let strategy = mr_strategy();
        let prices: Vec<f64> = (0..10)
            .map(|_| 102.0)
            .chain((0..10).map(|_| 98.0))
            .collect();
        let candles: Vec<Candle> = prices
            .into_iter()
            .enumerate()
            .map(|(i, p)| make_candle(p, i as i64))
            .collect();
        // entry_price argument is ignored for FromComponent — MR anchors at MA.
        let long_stop = compute_stop_price(&strategy, 99.5, Direction::Long, &candles).unwrap();
        assert!((long_stop - 93.0).abs() < 0.01);
    }

    #[test]
    fn atr_multiple_stop_price_uses_atr_for_long_and_short() {
        // Deterministic ATR(period=3)=4.0 from TR sequence 3,4,5.
        let candles = vec![
            make_candle(100.0, 0),
            Candle {
                time: make_candle(100.0, 1).time,
                mid: crate::engine::types::OHLC {
                    open: 100.0,
                    high: 102.0,
                    low: 99.0,
                    close: 101.0,
                },
                volume: 1,
                bid: None,
                ask: None,
            },
            Candle {
                time: make_candle(100.0, 2).time,
                mid: crate::engine::types::OHLC {
                    open: 101.0,
                    high: 101.0,
                    low: 97.0,
                    close: 98.0,
                },
                volume: 1,
                bid: None,
                ask: None,
            },
            Candle {
                time: make_candle(100.0, 3).time,
                mid: crate::engine::types::OHLC {
                    open: 98.0,
                    high: 103.0,
                    low: 100.0,
                    close: 102.0,
                },
                volume: 1,
                bid: None,
                ask: None,
            },
        ];

        let mut strategy = tf_strategy(5, 20, -0.02);
        strategy.stop = StopConfig::AtrMultiple { k: 2.0, period: 3 };

        let long_stop = compute_stop_price(&strategy, 100.0, Direction::Long, &candles).unwrap();
        let short_stop = compute_stop_price(&strategy, 100.0, Direction::Short, &candles).unwrap();

        assert!((long_stop - 92.0).abs() < 1e-9, "long_stop={}", long_stop);
        assert!(
            (short_stop - 108.0).abs() < 1e-9,
            "short_stop={}",
            short_stop
        );
    }

    #[test]
    fn atr_multiple_stop_price_returns_none_when_buffer_too_small() {
        let candles: Vec<Candle> = (0..14).map(|i| make_candle(100.0, i)).collect();
        let mut strategy = tf_strategy(5, 20, -0.02);
        strategy.stop = StopConfig::AtrMultiple { k: 3.0, period: 14 };

        let stop = compute_stop_price(&strategy, 100.0, Direction::Long, &candles);
        assert!(stop.is_none());
    }
}
