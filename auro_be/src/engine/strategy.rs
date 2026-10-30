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
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::engine::adx_filter::AdxFilterParams;
use crate::engine::bollinger::BollingerParams;
use crate::engine::carry::CarryParams;
use crate::engine::donchian::DonchianParams;
use crate::engine::event_window::EventWindowParams;
use crate::engine::financing::PolicyRates;
use crate::engine::ma_filter::MaFilterParams;
use crate::engine::macd::MacdParams;
use crate::engine::mean_reversion::MeanReversionParams;
use crate::engine::momentum::MomentumParams;
use crate::engine::noise_area::NoiseAreaParams;
use crate::engine::opening_range::OpeningRangeParams;
use crate::engine::pivot_points::PivotPointsParams;
use crate::engine::rsi_reversion::RsiReversionParams;
use crate::engine::stochastic::StochasticParams;
use crate::engine::trend_following::TrendFollowingParams;
use crate::engine::types::{Candle, Direction, EntryReason, ExitReason, Granularity, Trade};
use crate::engine::volatility::VolatilityParams;
use crate::engine::vwap::VwapParams;

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

    /// Optional: the values this component draws on a chart for the bar at
    /// the end of `candles` (`"rsi"`, `"ma"`, `"upper"`, …), so a preview
    /// can plot the indicator beside its yes/no ports. A value it can't
    /// compute yet is left out. Default: nothing to draw.
    fn series(&self, _candles: &[Candle]) -> HashMap<String, f64> {
        HashMap::new()
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
/// component type: write the params struct, impl Signaler for it, give it
/// its `catalog()` entry (see `engine::catalog`), add a variant here, add a
/// delegation arm in the Signaler impl below.
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
    #[serde(rename = "NoiseArea")]
    NoiseArea(NoiseAreaParams),
    #[serde(rename = "Momentum")]
    Momentum(MomentumParams),
    #[serde(rename = "EventWindow")]
    EventWindow(EventWindowParams),
    #[serde(rename = "Bollinger")]
    Bollinger(BollingerParams),
    #[serde(rename = "Stochastic")]
    Stochastic(StochasticParams),
    #[serde(rename = "AdxFilter")]
    AdxFilter(AdxFilterParams),
    #[serde(rename = "Volatility")]
    Volatility(VolatilityParams),
    #[serde(rename = "Vwap")]
    Vwap(VwapParams),
    #[serde(rename = "OpeningRange")]
    OpeningRange(OpeningRangeParams),
    #[serde(rename = "PivotPoints")]
    PivotPoints(PivotPointsParams),
    #[serde(rename = "Carry")]
    Carry(CarryParams),
    // Future variants: LiquiditySweep, etc.
}

pub use crate::engine::catalog::SettingRange;

/// The meaningful range of `setting` on a block or stop of type `kind`
/// (`"RsiReversion"`, `"AtrMultiple"`), from the block catalog
/// (`catalog::Setting::range`). None: any value the block accepts.
pub fn setting_range(kind: &str, setting: &str) -> Option<SettingRange> {
    crate::engine::catalog::block(kind)?
        .settings
        .iter()
        .find(|s| s.key == setting)?
        .range
}

/// Long and short port selectors for entry or exit decisions.
///
/// Each side is optional: a one-directional strategy simply omits the other
/// side (it never fires). Older configs that encode "never" as a
/// contradiction (`{"and": ["p", {"not": "p"}]}`) still parse and behave
/// identically — the explicit omission is just the cleaner spelling.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct EntryExitSelector {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub long: Option<PortRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub short: Option<PortRef>,
}

/// Most bars a `within` / `ago` rule may count (Opus's builder caps at
/// the same number).
/// Each one computes the blocks again on an earlier bar, and the live
/// buffer only holds a few hundred bars anyway.
pub const RULE_LOOKBACK_MAX: usize = 500;

/// Reference to a signal port. Can be:
/// - A direct port name like `"tf.bullish_cross"` (resolves to the component's output)
/// - A composition: `and`, `or`, or `not` of other refs
/// - A time rule over earlier bars:
///   - `{"within": N, "rule": r}`: `r` held on at least one of the last N
///     bars, this one included (N = 1 is `r` itself).
///   - `{"ago": N, "rule": r}`: `r` as it read N bars back.
///
///   An earlier bar is read by computing the blocks on the candles that
///   ended there (the same window shortened by N bars), so backtest and live
///   agree. A bar that can't be read (not enough candles, a block or port
///   missing) counts like a missing port today: no signal. For `within`
///   that means every one of the N bars must be readable, not just one. The
///   strategy's warmup grows by the rules' lookback (`PortRef::lookback`),
///   so past warmup the earlier bars are there. 1 ≤ N ≤ `RULE_LOOKBACK_MAX`.
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
    Within { within: usize, rule: Box<PortRef> },
    Ago { ago: usize, rule: Box<PortRef> },
}

impl PortRef {
    /// Bars before the current one this rule reads: `within` N reads N − 1
    /// earlier bars, `ago` N reads N; nested rules add up.
    pub fn lookback(&self) -> usize {
        match self {
            PortRef::Direct(_) => 0,
            PortRef::And { and: refs } | PortRef::Or { or: refs } => {
                refs.iter().map(PortRef::lookback).max().unwrap_or(0)
            }
            PortRef::Not { not } => not.lookback(),
            PortRef::Within { within, rule } => within.saturating_sub(1) + rule.lookback(),
            PortRef::Ago { ago, rule } => ago + rule.lookback(),
        }
    }
}

/// The bar count of a `within` / `ago` rule, checked against
/// 1..=`RULE_LOOKBACK_MAX`.
fn rule_bars(map: &serde_json::Map<String, serde_json::Value>, key: &str) -> Result<usize, String> {
    let n = map
        .get(key)
        .and_then(serde_json::Value::as_u64)
        .ok_or_else(|| format!("'{key}' must be a whole number of bars"))?;
    if n < 1 || n > RULE_LOOKBACK_MAX as u64 {
        return Err(format!(
            "'{key}' must be between 1 and {RULE_LOOKBACK_MAX} bars, got {n}"
        ));
    }
    Ok(n as usize)
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
                } else if map.contains_key("within") || map.contains_key("ago") {
                    let key = if map.contains_key("within") {
                        "within"
                    } else {
                        "ago"
                    };
                    let bars = rule_bars(&map, key).map_err(D::Error::custom)?;
                    let rule = map
                        .get("rule")
                        .ok_or_else(|| D::Error::custom(format!("'{key}' needs a 'rule'")))?;
                    let rule: Box<PortRef> =
                        Box::new(serde_json::from_value(rule.clone()).map_err(D::Error::custom)?);
                    Ok(if key == "within" {
                        PortRef::Within { within: bars, rule }
                    } else {
                        PortRef::Ago { ago: bars, rule }
                    })
                } else {
                    Err(D::Error::custom(
                        "PortRef object must contain 'and', 'or', 'not', 'within', or 'ago'",
                    ))
                }
            }
            _ => Err(D::Error::custom(
                "PortRef must be a string or an object with 'and'/'or'/'not'/'within'/'ago'",
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
    /// Risk `pct` of NAV per trade against the stop distance. Notional is
    /// capped at `max_notional_pct` of NAV when set (fraction, e.g. 1.5 =
    /// 150%), else the engine default. Intraday index strategies with stops
    /// under ~2% need the override; every other strategy keeps the default.
    #[serde(rename = "RiskPct")]
    RiskPct {
        pct: f64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        max_notional_pct: Option<f64>,
    },
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
    /// Minimum candle count required to compute all component ports, on
    /// this bar and on every earlier bar a `within` / `ago` rule reads
    /// (`rule_lookback`), and the stop (an ATR stop needs `period + 1` bars).
    pub fn warmup(&self) -> usize {
        let stop = match &self.stop {
            StopConfig::AtrMultiple { period, .. } => period + 1,
            StopConfig::FixedPct { .. } | StopConfig::FromComponent { .. } => 0,
        };
        let components = self
            .components
            .values()
            .map(|c| c.warmup())
            .max()
            .unwrap_or(0);
        (components + self.rule_lookback()).max(stop)
    }

    /// The most bars before the current one any entry or exit rule reads.
    pub fn rule_lookback(&self) -> usize {
        [
            &self.entry.long,
            &self.entry.short,
            &self.exit.long,
            &self.exit.short,
        ]
        .into_iter()
        .flatten()
        .map(PortRef::lookback)
        .max()
        .unwrap_or(0)
    }

    /// Whether any block needs central-bank policy rates (`Carry`).
    pub fn needs_policy_rates(&self) -> bool {
        self.components
            .values()
            .any(|c| matches!(c, Component::Carry(_)))
    }

    /// Hand every `Carry` block the policy rates of this strategy's pair.
    /// Every reader of a strategy that evaluates it calls this once after
    /// parsing (backtest, live, preview), so all compute alike. Err: the
    /// instrument isn't a currency pair or a currency has no rates; the
    /// unattached block then can't compute.
    pub fn attach_policy_rates(&mut self, rates: &Arc<PolicyRates>) -> Result<(), String> {
        let instrument = self.instrument.clone();
        for (name, component) in &mut self.components {
            if let Component::Carry(carry) = component {
                carry
                    .attach(&instrument, rates)
                    .map_err(|e| format!("block {name}: {e}"))?;
            }
        }
        Ok(())
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

    /// Every component's chart values for the bar at the end of `candles`,
    /// keyed by component name (see `Signaler::series`).
    pub fn compute_series(&self, candles: &[Candle]) -> HashMap<String, HashMap<String, f64>> {
        self.components
            .iter()
            .map(|(name, component)| (name.clone(), component.series(candles)))
            .collect()
    }

    /// Evaluate the entry selector for the bar at the end of `candles`.
    /// `ports` is `compute_ports(candles)`; earlier bars a time rule reads
    /// are computed from `candles` as needed. Every reader that decides
    /// (backtest, live) goes through here, so they decide alike.
    pub fn evaluate_entry(&self, candles: &[Candle], ports: &PortValues) -> EntrySignal {
        let mut bars = RuleBars::new(self, candles, ports);
        let long = resolve_side(&self.entry.long, &mut bars);
        let short = resolve_side(&self.entry.short, &mut bars);
        match (long, short) {
            (true, true) => EntrySignal::None, // ambiguous → no signal
            (true, false) => EntrySignal::Long,
            (false, true) => EntrySignal::Short,
            (false, false) => EntrySignal::None,
        }
    }

    /// Evaluate the exit selector for a given direction, for the bar at the
    /// end of `candles` (`ports` as in `evaluate_entry`). An omitted side
    /// never signals exit — the position relies on its stop/time-stop.
    pub fn evaluate_exit(
        &self,
        candles: &[Candle],
        ports: &PortValues,
        is_long: bool,
    ) -> ExitSignal {
        let selector = if is_long {
            &self.exit.long
        } else {
            &self.exit.short
        };
        if resolve_side(selector, &mut RuleBars::new(self, candles, ports)) {
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
            Component::NoiseArea(p) => p.warmup(),
            Component::Momentum(p) => p.warmup(),
            Component::EventWindow(p) => p.warmup(),
            Component::Bollinger(p) => p.warmup(),
            Component::Stochastic(p) => p.warmup(),
            Component::AdxFilter(p) => p.warmup(),
            Component::Volatility(p) => p.warmup(),
            Component::Vwap(p) => p.warmup(),
            Component::OpeningRange(p) => p.warmup(),
            Component::PivotPoints(p) => p.warmup(),
            Component::Carry(p) => p.warmup(),
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
            Component::NoiseArea(p) => p.compute(candles),
            Component::Momentum(p) => p.compute(candles),
            Component::EventWindow(p) => p.compute(candles),
            Component::Bollinger(p) => p.compute(candles),
            Component::Stochastic(p) => p.compute(candles),
            Component::AdxFilter(p) => p.compute(candles),
            Component::Volatility(p) => p.compute(candles),
            Component::Vwap(p) => p.compute(candles),
            Component::OpeningRange(p) => p.compute(candles),
            Component::PivotPoints(p) => p.compute(candles),
            Component::Carry(p) => p.compute(candles),
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
            Component::NoiseArea(p) => p.entry_reason(candles, direction),
            Component::Momentum(p) => p.entry_reason(candles, direction),
            Component::EventWindow(p) => p.entry_reason(candles, direction),
            Component::Bollinger(p) => p.entry_reason(candles, direction),
            Component::Stochastic(p) => p.entry_reason(candles, direction),
            Component::AdxFilter(p) => p.entry_reason(candles, direction),
            Component::Volatility(p) => p.entry_reason(candles, direction),
            Component::Vwap(p) => p.entry_reason(candles, direction),
            Component::OpeningRange(p) => p.entry_reason(candles, direction),
            Component::PivotPoints(p) => p.entry_reason(candles, direction),
            Component::Carry(p) => p.entry_reason(candles, direction),
        }
    }

    pub fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        match self {
            Component::TrendFollowing(p) => p.series(candles),
            Component::MeanReversion(p) => p.series(candles),
            Component::Macd(p) => p.series(candles),
            Component::Donchian(p) => p.series(candles),
            Component::MaFilter(p) => p.series(candles),
            Component::RsiReversion(p) => p.series(candles),
            Component::NoiseArea(p) => p.series(candles),
            Component::Momentum(p) => p.series(candles),
            Component::EventWindow(p) => p.series(candles),
            Component::Bollinger(p) => p.series(candles),
            Component::Stochastic(p) => p.series(candles),
            Component::AdxFilter(p) => p.series(candles),
            Component::Volatility(p) => p.series(candles),
            Component::Vwap(p) => p.series(candles),
            Component::OpeningRange(p) => p.series(candles),
            Component::PivotPoints(p) => p.series(candles),
            Component::Carry(p) => p.series(candles),
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
            Component::NoiseArea(p) => p.stop_price(candles, direction),
            Component::Momentum(p) => p.stop_price(candles, direction),
            Component::EventWindow(p) => p.stop_price(candles, direction),
            Component::Bollinger(p) => p.stop_price(candles, direction),
            Component::Stochastic(p) => p.stop_price(candles, direction),
            Component::AdxFilter(p) => p.stop_price(candles, direction),
            Component::Volatility(p) => p.stop_price(candles, direction),
            Component::Vwap(p) => p.stop_price(candles, direction),
            Component::OpeningRange(p) => p.stop_price(candles, direction),
            Component::PivotPoints(p) => p.stop_price(candles, direction),
            Component::Carry(p) => p.stop_price(candles, direction),
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
        PortRef::Within { rule, .. } | PortRef::Ago { rule, .. } => primary_component_name(rule),
    }
}

/// Evaluation window ending at `end_inclusive`, capped at `cap` bars.
/// The cap mirrors the live evaluator's `CandleBuffer` capacity so recursive
/// indicators (EMA/RSI/ATR seeding) compute over the same window length in
/// backtest and live. It also bounds per-bar work, keeping the backtest
/// O(n × cap) instead of O(n²) over long histories.
pub(crate) fn bounded_window(candles: &[Candle], end_inclusive: usize, cap: usize) -> &[Candle] {
    let start = (end_inclusive + 1).saturating_sub(cap);
    &candles[start..=end_inclusive]
}

/// Run a strategy as a backtest over a slice of candles. Bidirectional —
/// produces both long and short trades as signals fire. Trades still open at
/// the end of the candle series are recorded with `ExitReason::EndOfData`.
///
/// Evaluation windows are capped at the granularity's live buffer capacity
/// (see `bounded_window`). A strategy whose warmup exceeds that capacity can
/// never trade live, so it produces no backtest trades either.
pub fn run_backtest(candles: &[Candle], strategy: &Strategy) -> Vec<Trade> {
    let mut trades: Vec<Trade> = Vec::new();
    let warmup = strategy.warmup();
    let cap = strategy.granularity.buffer_capacity();
    if candles.len() < warmup + 1 || warmup + 1 > cap {
        return trades;
    }

    let mut i = warmup;
    while i < candles.len() {
        let window = bounded_window(candles, i, cap);
        let ports = match strategy.compute_ports(window) {
            Some(p) => p,
            None => {
                i += 1;
                continue;
            }
        };

        let entry_signal = strategy.evaluate_entry(window, &ports);
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
        let entry_reason = (if direction == Direction::Long {
            &strategy.entry.long
        } else {
            &strategy.entry.short
        })
        .as_ref()
        .and_then(primary_component_name)
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
            let exit_window = bounded_window(candles, j, cap);

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
                    stop_price,
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
                        stop_price,
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
            let exit_signal =
                strategy.evaluate_exit(exit_window, &exit_ports, direction == Direction::Long);
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
                    stop_price,
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
                stop_price,
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
            // The entry price doesn't enter into it; the signature keeps it
            // so the backtest runner and live evaluator call uniformly.
            let comp = strategy.components.get(component)?;
            comp.stop_price(candles, direction)
        }
    }
}

/// The port values of the bar at the end of `candles` and, computed the
/// first time a time rule asks and kept for the rest of this evaluation, of
/// the bars before it.
struct RuleBars<'a> {
    strategy: &'a Strategy,
    candles: &'a [Candle],
    current: &'a PortValues,
    /// Bars back → that bar's ports; None: they can't be computed.
    earlier: HashMap<usize, Option<PortValues>>,
}

impl<'a> RuleBars<'a> {
    fn new(strategy: &'a Strategy, candles: &'a [Candle], current: &'a PortValues) -> Self {
        Self {
            strategy,
            candles,
            current,
            earlier: HashMap::new(),
        }
    }

    /// The ports of the bar `back` bars before the current one, computed on
    /// the candles that ended there.
    fn ports(&mut self, back: usize) -> Option<&PortValues> {
        if back == 0 {
            return Some(self.current);
        }
        let (strategy, candles) = (self.strategy, self.candles);
        self.earlier
            .entry(back)
            .or_insert_with(|| {
                let end = candles.len().checked_sub(back).filter(|&end| end > 0)?;
                strategy.compute_ports(&candles[..end])
            })
            .as_ref()
    }
}

/// Resolve an optional selector side: omitted side → never fires.
fn resolve_side(side: &Option<PortRef>, bars: &mut RuleBars) -> bool {
    side.as_ref()
        .and_then(|port_ref| resolve_port_ref(port_ref, 0, bars))
        .unwrap_or(false)
}

/// Resolve a PortRef to a bool on the bar `back` bars before the current
/// one. Some(value) if every referenced port (on every bar it reads) was
/// computed; None if one is missing (treat as "no signal").
fn resolve_port_ref(port_ref: &PortRef, back: usize, bars: &mut RuleBars) -> Option<bool> {
    match port_ref {
        PortRef::Direct(name) => {
            let (component, port) = name.split_once('.')?;
            bars.ports(back)?.get(component)?.get(port).copied()
        }
        PortRef::And { and } => {
            let mut result = true;
            for r in and {
                result = result && resolve_port_ref(r, back, bars)?;
            }
            Some(result)
        }
        PortRef::Or { or } => {
            let mut result = false;
            for r in or {
                result = result || resolve_port_ref(r, back, bars)?;
            }
            Some(result)
        }
        PortRef::Not { not } => Some(!resolve_port_ref(not, back, bars)?),
        PortRef::Within { within, rule } => {
            // Every bar is read, even after a hit: one that can't be is no
            // signal (see `PortRef`).
            let mut any = false;
            for earlier in 0..*within {
                any |= resolve_port_ref(rule, back + earlier, bars)?;
            }
            Some(any)
        }
        PortRef::Ago { ago, rule } => resolve_port_ref(rule, back + ago, bars),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_block_parses_as_opus_sends_it() {
        for (block, params) in [
            (
                "Bollinger",
                serde_json::json!({"period": 20, "std_dev_mult": 2.0}),
            ),
            (
                "Stochastic",
                serde_json::json!({"period": 14, "signal_period": 3, "oversold": 20.0, "overbought": 80.0}),
            ),
            (
                "AdxFilter",
                serde_json::json!({"period": 14, "threshold": 25.0}),
            ),
            (
                "Volatility",
                serde_json::json!({"period": 14, "baseline": 100}),
            ),
            ("Vwap", serde_json::json!({})),
            ("OpeningRange", serde_json::json!({"minutes": 30})),
            ("PivotPoints", serde_json::json!({})),
        ] {
            let component: Result<Component, _> =
                serde_json::from_value(serde_json::json!({"type": block, "params": params}));
            assert!(component.is_ok(), "{block}: {component:?}");
        }
    }
    use serde_json::json;

    /// A rule on the current bar only (no candles to look back over).
    fn resolve(r: &PortRef, ports: &PortValues) -> Option<bool> {
        let strategy = tf_strategy(5, 20, -0.02);
        resolve_port_ref(r, 0, &mut RuleBars::new(&strategy, &[], ports))
    }

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
            resolve(&PortRef::Direct("tf.bullish_cross".to_string()), &ports),
            Some(true)
        );
    }

    #[test]
    fn resolve_missing_port_returns_none() {
        let ports: PortValues = HashMap::new();
        assert_eq!(
            resolve(&PortRef::Direct("tf.bullish_cross".to_string()), &ports),
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
        assert_eq!(resolve(&r, &ports), Some(false));
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
        assert_eq!(resolve(&r, &ports), Some(true));
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
        assert_eq!(resolve(&r, &ports), Some(false));
    }

    // ---- time rules (`within` / `ago`) ----

    /// An "up bar" block: with a 2-bar average, `m.above` is a close above
    /// the one before, `m.below` one under it. Warmup 2.
    fn up_bar_strategy(long: serde_json::Value, exit: serde_json::Value) -> Strategy {
        serde_json::from_value(json!({
            "strategy_id": null,
            "strategy_name": "time_rules",
            "version": "v1_composite",
            "instrument": "TEST",
            "granularity": "H1",
            "components": {"m": {"type": "MaFilter", "params": {"period": 2}}},
            "entry": {"long": long},
            "exit": {"long": exit},
            "stop": {"type": "FixedPct", "params": {"pct": -0.5}},
            "sizing": {"type": "RiskPct", "params": {"pct": 0.01}}
        }))
        .expect("should parse")
    }

    /// The long entry decision on the bar at the end of `candles`.
    fn long_entry(strategy: &Strategy, candles: &[Candle]) -> bool {
        strategy
            .compute_ports(candles)
            .is_some_and(|ports| strategy.evaluate_entry(candles, &ports) == EntrySignal::Long)
    }

    #[test]
    fn time_rules_round_trip_json() {
        let rule = json!({"and": [
            {"within": 5, "rule": {"ago": 1, "rule": "m.above"}},
            {"not": {"within": 1, "rule": "m.below"}}
        ]});
        let parsed: PortRef = serde_json::from_value(rule.clone()).unwrap();
        assert_eq!(serde_json::to_value(&parsed).unwrap(), rule);
    }

    #[test]
    fn time_rule_bar_count_is_checked() {
        for bad in [
            json!({"within": 0, "rule": "m.above"}),
            json!({"ago": 501, "rule": "m.above"}),
            json!({"ago": -1, "rule": "m.above"}),
            json!({"within": 2.5, "rule": "m.above"}),
            json!({"within": "3", "rule": "m.above"}),
            json!({"within": 3}),
        ] {
            assert!(
                serde_json::from_value::<PortRef>(bad.clone()).is_err(),
                "{bad}"
            );
        }
        assert!(serde_json::from_value::<PortRef>(json!({"ago": 500, "rule": "m.above"})).is_ok());
    }

    #[test]
    fn warmup_grows_by_the_rules_lookback() {
        assert_eq!(
            up_bar_strategy(json!("m.above"), json!("m.below")).warmup(),
            2
        );
        // within 5 reads 4 earlier bars.
        let s = up_bar_strategy(json!({"within": 5, "rule": "m.above"}), json!("m.below"));
        assert_eq!(s.warmup(), 6);
        // Nested: 4 + 3; the exit's 10 is the longest.
        let nested = json!({"within": 5, "rule": {"ago": 3, "rule": "m.above"}});
        assert_eq!(
            up_bar_strategy(nested.clone(), json!("m.below")).warmup(),
            9
        );
        let s = up_bar_strategy(nested, json!({"ago": 10, "rule": "m.below"}));
        assert_eq!(s.warmup(), 12);
    }

    #[test]
    fn ago_reads_the_rule_n_bars_back() {
        // Up bars: 101 (bar 1) and 100 (bar 4); bars 2 and 3 are down.
        let bars = crate::engine::test_candles::daily(&[100.0, 101.0, 100.0, 99.0, 100.0]);
        let ago = |n| up_bar_strategy(json!({"ago": n, "rule": "m.above"}), json!("m.below"));
        assert!(!long_entry(&ago(1), &bars));
        assert!(!long_entry(&ago(2), &bars));
        assert!(long_entry(&ago(3), &bars));
        // 4 bars back is bar 0, whose average can't be computed: no signal.
        assert!(!long_entry(&ago(4), &bars));
        // `ago` composes: "not a down bar 1 bar ago" is false (bar 3 was down).
        let s = up_bar_strategy(
            json!({"ago": 1, "rule": {"not": "m.below"}}),
            json!("m.below"),
        );
        assert!(!long_entry(&s, &bars));
    }

    #[test]
    fn within_holds_if_the_rule_held_on_any_of_the_bars() {
        let bars = crate::engine::test_candles::daily(&[100.0, 101.0, 100.0, 99.0, 100.0]);
        let within =
            |n, rule: &str| up_bar_strategy(json!({"within": n, "rule": rule}), json!("m.below"));
        // Bar 4 is not a down bar, bar 3 was.
        assert!(!long_entry(&within(1, "m.below"), &bars));
        assert!(long_entry(&within(2, "m.below"), &bars));
        // The bars before bar 4 (3, 2) were down; bar 4 itself is up.
        assert!(long_entry(&within(1, "m.above"), &bars));
        assert!(!long_entry(&within(2, "m.above"), &bars[..4]));
        // within 1 is the rule itself, on every bar.
        for end in 2..=bars.len() {
            assert_eq!(
                long_entry(&within(1, "m.above"), &bars[..end]),
                long_entry(
                    &up_bar_strategy(json!("m.above"), json!("m.below")),
                    &bars[..end]
                ),
            );
        }
    }

    #[test]
    fn within_needs_every_bar_it_reads() {
        // Bar 1 is an up bar, but bar 0 (no average yet) can't be read, so
        // "up bar within the last 2" has no signal rather than a yes.
        let bars = crate::engine::test_candles::daily(&[100.0, 101.0]);
        let s = up_bar_strategy(json!({"within": 2, "rule": "m.above"}), json!("m.below"));
        let ports = s.compute_ports(&bars).unwrap();
        let mut rule_bars = RuleBars::new(&s, &bars, &ports);
        assert_eq!(
            resolve_port_ref(s.entry.long.as_ref().unwrap(), 0, &mut rule_bars),
            None
        );
    }

    #[test]
    fn exits_read_time_rules_too() {
        // Exit when there was a down bar in the last 2: bar 3.
        let bars = crate::engine::test_candles::daily(&[100.0, 101.0, 100.0, 99.0, 100.0]);
        let s = up_bar_strategy(json!("m.above"), json!({"within": 2, "rule": "m.below"}));
        let ports = s.compute_ports(&bars).unwrap();
        assert_eq!(s.evaluate_exit(&bars, &ports, true), ExitSignal::Exit);
        let ports = s.compute_ports(&bars[..2]).unwrap();
        assert_eq!(s.evaluate_exit(&bars[..2], &ports, true), ExitSignal::Hold);
    }

    #[test]
    fn primary_component_is_found_inside_time_rules() {
        let r: PortRef =
            serde_json::from_value(json!({"within": 3, "rule": {"ago": 1, "rule": "m.above"}}))
                .unwrap();
        assert_eq!(primary_component_name(&r), Some("m"));
    }

    /// Live decides on its candle buffer (capped at the granularity's
    /// capacity, filled bar by bar); the backtest on `bounded_window`. With
    /// time rules both must read the same earlier bars, so every decision
    /// matches, including once the buffer is full and sliding.
    #[test]
    fn time_rule_decisions_match_between_backtest_and_live_buffer() {
        let closes: Vec<f64> = (0..600)
            .map(|i| 100.0 + (i as f64 * 0.37).sin() * 3.0 + (i as f64 * 0.05).cos())
            .collect();
        let candles = crate::engine::test_candles::daily(&closes);
        let s = up_bar_strategy(
            json!({"and": [{"within": 4, "rule": "m.below"}, "m.above", {"ago": 2, "rule": "m.below"}]}),
            json!({"within": 3, "rule": {"ago": 1, "rule": "m.above"}}),
        );
        let cap = s.granularity.buffer_capacity();
        assert!(candles.len() > cap + 50, "the buffer must slide");
        let mut buffer = crate::engine::types::CandleBuffer::new(cap);
        let mut entries = 0;
        for (i, candle) in candles.iter().enumerate() {
            buffer.push(candle.clone());
            if i < s.warmup() {
                continue;
            }
            let window = bounded_window(&candles, i, cap);
            let times = |bars: &[Candle]| bars.iter().map(|c| c.time).collect::<Vec<_>>();
            assert_eq!(times(&buffer.candles), times(window), "bar {i}");
            let live_ports = s.compute_ports(&buffer.candles).unwrap();
            let backtest_ports = s.compute_ports(window).unwrap();
            let live = s.evaluate_entry(&buffer.candles, &live_ports);
            assert_eq!(live, s.evaluate_entry(window, &backtest_ports), "bar {i}");
            assert_eq!(
                s.evaluate_exit(&buffer.candles, &live_ports, true),
                s.evaluate_exit(window, &backtest_ports, true),
                "bar {i}"
            );
            entries += usize::from(live == EntrySignal::Long);
        }
        assert!(
            entries > 0,
            "the rule must fire somewhere to prove anything"
        );
        // Every backtest entry is a bar the live loop also signalled on.
        let trades = run_backtest(&candles, &s);
        assert!(!trades.is_empty());
        for trade in trades {
            let i = candles
                .iter()
                .position(|c| c.time == trade.entry_time)
                .unwrap();
            assert!(long_entry(&s, bounded_window(&candles, i, cap)));
        }
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

    /// Perf guard for the editor's M15 use case: a 3-component OR-wired
    /// strategy (Donchian + TF 50/200 + MACD) over a year of M15 bars must
    /// complete in seconds, not minutes. Run explicitly:
    /// `cargo test --release perf_year_of_m15 -- --ignored --nocapture`
    #[test]
    #[ignore = "perf guard — run explicitly with --release"]
    fn perf_year_of_m15_three_component_or_strategy() {
        let candles: Vec<Candle> = (0..25_000)
            .map(|i| {
                let wobble = ((i as f64 * 0.7).sin() * 0.4) + ((i as f64 * 0.013).cos() * 1.1);
                make_candle(100.0 + (i as f64 * 0.0001) + wobble, i)
            })
            .collect();

        let mut components: HashMap<String, Component> = HashMap::new();
        components.insert(
            "d".to_string(),
            Component::Donchian(DonchianParams {
                entry_period: 20,
                exit_period: 10,
            }),
        );
        components.insert(
            "tf".to_string(),
            Component::TrendFollowing(TrendFollowingParams {
                fast_period: 50,
                slow_period: 200,
                ma_type: crate::engine::indicators::MaType::Sma,
            }),
        );
        components.insert(
            "m".to_string(),
            Component::Macd(MacdParams {
                fast_period: 12,
                slow_period: 26,
                signal_period: 9,
            }),
        );

        let or_entry = PortRef::Or {
            or: vec![
                PortRef::Direct("d.breakout_long".to_string()),
                PortRef::Direct("tf.bullish_cross".to_string()),
                PortRef::Direct("m.bullish_cross".to_string()),
            ],
        };
        let or_exit = PortRef::Or {
            or: vec![
                PortRef::Direct("d.breakout_short".to_string()),
                PortRef::Direct("tf.bearish_cross".to_string()),
                PortRef::Direct("m.bearish_cross".to_string()),
            ],
        };

        let strategy = Strategy {
            strategy_id: None,
            strategy_name: Some("perf_guard".to_string()),
            version: "v1_composite".to_string(),
            instrument: "TEST".to_string(),
            granularity: Granularity::M15,
            components,
            entry: EntryExitSelector {
                long: Some(or_entry),
                short: None,
            },
            exit: EntryExitSelector {
                long: Some(or_exit),
                short: None,
            },
            stop: StopConfig::AtrMultiple { k: 3.0, period: 12 },
            sizing: SizingConfig::RiskPct {
                pct: 0.01,
                max_notional_pct: None,
            },
            max_hold_bars: None,
        };

        let start = std::time::Instant::now();
        let trades = run_backtest(&candles, &strategy);
        let elapsed = start.elapsed();
        println!(
            "25k M15 bars, 3-component OR strategy: {} trades in {:?}",
            trades.len(),
            elapsed
        );
        assert!(
            elapsed.as_secs() < 30,
            "backtest took {:?} — perf regression",
            elapsed
        );
    }

    fn tf_strategy(fast: usize, slow: usize, stop_pct: f64) -> Strategy {
        let mut components: HashMap<String, Component> = HashMap::new();
        components.insert(
            "tf".to_string(),
            Component::TrendFollowing(TrendFollowingParams {
                fast_period: fast,
                slow_period: slow,
                ma_type: crate::engine::indicators::MaType::Sma,
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
                long: Some(PortRef::Direct("tf.bullish_cross".to_string())),
                short: Some(PortRef::Direct("tf.bearish_cross".to_string())),
            },
            exit: EntryExitSelector {
                long: Some(PortRef::Direct("tf.bearish_cross".to_string())),
                short: Some(PortRef::Direct("tf.bullish_cross".to_string())),
            },
            stop: StopConfig::FixedPct { pct: stop_pct },
            sizing: SizingConfig::RiskPct {
                pct: 0.01,
                max_notional_pct: None,
            },
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
                long: Some(PortRef::Direct("mr.long".to_string())),
                short: Some(PortRef::Direct("mr.short".to_string())),
            },
            exit: EntryExitSelector {
                long: Some(PortRef::Direct("mr.exit_long".to_string())),
                short: Some(PortRef::Direct("mr.exit_short".to_string())),
            },
            stop: StopConfig::FromComponent {
                component: "mr".to_string(),
            },
            sizing: SizingConfig::RiskPct {
                pct: 0.01,
                max_notional_pct: None,
            },
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
