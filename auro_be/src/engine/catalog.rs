//! The block catalog: every fact about a strategy block other than its
//! maths, in one place. Each block file declares its own entry next to its
//! code (`pub(crate) fn catalog() -> Block`): its name and what it watches
//! in plain words, its settings (kind, default, the range where it means
//! something and why), its ports with the words each one reads as, the
//! values it draws, and the words for its own stop.
//!
//! `setting_range` reads the ranges from here, and a test writes the whole
//! catalog to `opus/priv/block_catalog.json`, which Opus compiles into the
//! strategy builder (`Opus.Trading.Blocks`) and the plain-words rules
//! (`Opus.Trading.StrategyWords`). The test fails when that file is stale.
//!
//! Adding a block:
//! 1. Write the block file (params struct + `Signaler`) with its
//!    `catalog()` entry, add its `Component` variant and dispatch arms in
//!    `strategy.rs`, and its entry to `blocks()` below.
//! 2. `UPDATE_CATALOG=1 cargo test catalog` to regenerate the JSON.
//! 3. In Opus, put its type in a group in `Opus.Trading.Blocks` (or in
//!    `@hidden` if the builder shouldn't offer it); a test there fails
//!    until you do.
//!
//! Port words are templates: `{setting}` is the setting's value (a number,
//! or the words its `reads` cases give), `{setting:bars}` is a count of
//! bars ("20 days", "1 hour"), and `{setting:bars|1}` falls back to 1 when
//! the setting is empty. A setting left out of a recipe reads as its
//! default.

use std::sync::LazyLock;

use serde::Serialize;
use serde_json::Value;

use crate::engine::{
    adx_filter, bollinger, carry, donchian, event_window, ma_filter, macd, mean_reversion,
    momentum, noise_area, opening_range, pivot_points, rsi_reversion, stochastic, trend_following,
    volatility, vwap,
};

/// Every block, in the order the builder lists them.
fn blocks() -> Vec<Block> {
    vec![
        ma_filter::catalog(),
        trend_following::catalog(),
        rsi_reversion::catalog(),
        mean_reversion::catalog(),
        donchian::catalog(),
        noise_area::catalog(),
        macd::catalog(),
        momentum::catalog(),
        adx_filter::catalog(),
        bollinger::catalog(),
        stochastic::catalog(),
        opening_range::catalog(),
        volatility::catalog(),
        vwap::catalog(),
        pivot_points::catalog(),
        carry::catalog(),
        event_window::catalog(),
    ]
}

static CATALOG: LazyLock<Vec<Block>> = LazyLock::new(blocks);

/// The catalog, built once.
pub fn all() -> &'static [Block] {
    &CATALOG
}

/// The block of component type `kind` (`"RsiReversion"`), if any.
pub fn block(kind: &str) -> Option<&'static Block> {
    all().iter().find(|b| b.kind == kind)
}

// Why-texts more than one block shares.
pub(crate) const AVERAGE_WHY: &str = "an average over fewer than 2 bars is just the price";
pub(crate) const RSI_WHY: &str = "an RSI over fewer than 2 bars only reads 0 or 100";
pub(crate) const RSI_LEVEL_WHY: &str = "an RSI only reads between 0 and 100";
pub(crate) const SPREAD_WHY: &str = "a spread over fewer than 2 bars is always zero";
pub(crate) const SIGNAL_LINE_WHY: &str =
    "a signal line over fewer than 2 bars is the line itself, so the two never cross";

/// A strategy block.
#[derive(Debug, Clone, Serialize)]
pub struct Block {
    /// The component type in a recipe (`"RsiReversion"`).
    #[serde(rename = "type")]
    pub kind: &'static str,
    /// The name the builder gives the block in a recipe (`"r"`, then `"r2"`).
    pub key: &'static str,
    /// Its name in plain words.
    pub name: &'static str,
    /// What it watches, in one or two plain sentences.
    pub watches: &'static str,
    pub settings: Vec<Setting>,
    pub ports: Vec<Port>,
    /// The values it draws on a chart (`Signaler::series`).
    pub series: Vec<Series>,
    /// Its own stop (`StopConfig::FromComponent`) in words; None when it
    /// places no stop.
    pub stop: Option<&'static str>,
}

/// One setting of a block.
#[derive(Debug, Clone, Serialize)]
pub struct Setting {
    pub key: &'static str,
    pub label: &'static str,
    #[serde(flatten)]
    pub kind: Kind,
    /// The builder's starting value, and how a recipe without it reads.
    /// Null: empty (the setting is off).
    pub default: Value,
    pub help: &'static str,
    pub range: Option<SettingRange>,
    /// How `{key}` reads in port words when it isn't just the number: the
    /// first case that matches. Empty: the number.
    pub reads: Vec<Reads>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Kind {
    Int,
    Float,
    Bool,
    /// One of fixed values: `(value, label)`.
    Option {
        options: Vec<Choice>,
    },
}

#[derive(Debug, Clone, Serialize)]
pub struct Choice {
    pub value: &'static str,
    pub label: &'static str,
}

/// Where a block or stop setting stops meaning what the block is named for,
/// though the engine still computes it (an RSI over 1 bar only reads 0 or
/// 100). Code that moves settings on its own (the pipeline's
/// parameter-stability stage) stays inside it. A value of 0, or a fast
/// average no faster than the slow one, needs no range: the block refuses
/// to compute it at all.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct SettingRange {
    pub min: f64,
    /// Infinity (null in the JSON) for no upper bound.
    pub max: f64,
    /// Why, in plain words.
    pub why: &'static str,
}

/// One case of how a setting reads: `text` when the value matches `when`.
/// `{}` in `text` is the value.
#[derive(Debug, Clone, Serialize)]
pub struct Reads {
    pub when: When,
    pub text: &'static str,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum When {
    /// Exactly this value.
    Is(Value),
    /// A number above this one.
    Above(f64),
    /// Anything, empty included.
    Otherwise,
}

/// One port and the words it reads as (see the module docs for templates).
#[derive(Debug, Clone, Serialize)]
pub struct Port {
    pub key: &'static str,
    pub words: &'static str,
}

/// A value the block draws.
#[derive(Debug, Clone, Serialize)]
pub struct Series {
    pub key: &'static str,
    pub label: &'static str,
    pub place: Place,
    /// A panel's fixed scale.
    pub range: Option<[f64; 2]>,
    /// A panel's dashed reference lines.
    pub levels: Vec<Level>,
    /// A second series drawn in the same panel (a signal line).
    pub with: Option<&'static str>,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Place {
    /// A line on the candles.
    Price,
    /// Its own small chart under them.
    Panel,
}

/// A panel reference line: a setting's value, its negative, or a number.
#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
pub enum Level {
    Setting(&'static str),
    Neg { neg: &'static str },
    At(f64),
}

impl Setting {
    fn new(
        key: &'static str,
        label: &'static str,
        kind: Kind,
        default: Value,
        help: &'static str,
    ) -> Self {
        Setting {
            key,
            label,
            kind,
            default,
            help,
            range: None,
            reads: Vec::new(),
        }
    }

    /// A whole number (a bar count, minutes). `default` may be `Value::Null`.
    pub fn int(
        key: &'static str,
        label: &'static str,
        default: impl Into<Value>,
        help: &'static str,
    ) -> Self {
        Self::new(key, label, Kind::Int, default.into(), help)
    }

    pub fn float(
        key: &'static str,
        label: &'static str,
        default: impl Into<Value>,
        help: &'static str,
    ) -> Self {
        Self::new(key, label, Kind::Float, default.into(), help)
    }

    pub fn bool(key: &'static str, label: &'static str, default: bool, help: &'static str) -> Self {
        Self::new(key, label, Kind::Bool, default.into(), help)
    }

    pub fn option(
        key: &'static str,
        label: &'static str,
        options: &[(&'static str, &'static str)],
        default: &'static str,
        help: &'static str,
    ) -> Self {
        let options = options
            .iter()
            .map(|&(value, label)| Choice { value, label })
            .collect();
        Self::new(key, label, Kind::Option { options }, default.into(), help)
    }

    /// Meaningful from `min` up.
    pub fn at_least(self, min: f64, why: &'static str) -> Self {
        self.between(min, f64::INFINITY, why)
    }

    /// Meaningful from `min` to `max`.
    pub fn between(mut self, min: f64, max: f64, why: &'static str) -> Self {
        self.range = Some(SettingRange { min, max, why });
        self
    }

    /// How `{key}` reads in port words, first matching case first.
    pub fn reads(mut self, cases: Vec<(When, &'static str)>) -> Self {
        self.reads = cases
            .into_iter()
            .map(|(when, text)| Reads { when, text })
            .collect();
        self
    }
}

/// The moving-average kind setting `MaFilter` and `TrendFollowing` share.
pub(crate) fn ma_type() -> Setting {
    Setting::option(
        "ma_type",
        "Kind",
        &[("sma", "Simple"), ("ema", "Exponential")],
        "sma",
        "Exponential reacts faster to recent prices; simple weighs every bar the same.",
    )
    .reads(vec![
        (When::Is("ema".into()), "exponential"),
        (When::Otherwise, "simple"),
    ])
}

pub fn port(key: &'static str, words: &'static str) -> Port {
    Port { key, words }
}

impl Series {
    /// A line on the candles.
    pub fn price(key: &'static str, label: &'static str) -> Self {
        Series {
            key,
            label,
            place: Place::Price,
            range: None,
            levels: Vec::new(),
            with: None,
        }
    }

    /// Its own panel, with `levels` as reference lines.
    pub fn panel(key: &'static str, label: &'static str, levels: Vec<Level>) -> Self {
        Series {
            place: Place::Panel,
            levels,
            ..Self::price(key, label)
        }
    }

    pub fn range(mut self, min: f64, max: f64) -> Self {
        self.range = Some([min, max]);
        self
    }

    pub fn with(mut self, other: &'static str) -> Self {
        self.with = Some(other);
        self
    }
}

/// The catalog as the JSON Opus reads.
pub fn to_json() -> String {
    #[derive(Serialize)]
    struct File {
        about: &'static str,
        blocks: &'static [Block],
    }
    let file = File {
        about: "Generated from auro_be/src/engine/catalog.rs. Do not edit; regenerate with `UPDATE_CATALOG=1 cargo test catalog` in auro_be.",
        blocks: all(),
    };
    serde_json::to_string_pretty(&file).expect("the catalog serializes") + "\n"
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::strategy::Component;

    const FILE: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../opus/priv/block_catalog.json"
    );

    #[test]
    fn catalog_file_is_current() {
        let json = to_json();
        if std::env::var_os("UPDATE_CATALOG").is_some() {
            std::fs::write(FILE, &json).expect("write the catalog");
            return;
        }
        let committed = std::fs::read_to_string(FILE).unwrap_or_default();
        assert!(
            committed == json,
            "opus/priv/block_catalog.json is stale: run `UPDATE_CATALOG=1 cargo test catalog` in auro_be"
        );
    }

    /// Opus fills `EventWindow`'s settings itself (the event times), so it
    /// has none to offer here.
    const FILLED_BY_OPUS: &[&str] = &["EventWindow"];

    fn defaults(block: &Block) -> serde_json::Map<String, Value> {
        block
            .settings
            .iter()
            .filter(|s| !s.default.is_null())
            .map(|s| (s.key.to_string(), s.default.clone()))
            .collect()
    }

    fn parse(kind: &str, params: &serde_json::Map<String, Value>) -> Result<Value, String> {
        let component: Component =
            serde_json::from_value(serde_json::json!({"type": kind, "params": params}))
                .map_err(|e| e.to_string())?;
        Ok(serde_json::to_value(component).unwrap()["params"].clone())
    }

    fn same(a: &Value, b: &Value) -> bool {
        match (a.as_f64(), b.as_f64()) {
            (Some(x), Some(y)) => x == y,
            _ => a == b,
        }
    }

    #[test]
    fn settings_and_defaults_match_the_engine() {
        for block in all().iter().filter(|b| !FILLED_BY_OPUS.contains(&b.kind)) {
            let defaults = defaults(block);
            let parsed = parse(block.kind, &defaults)
                .unwrap_or_else(|e| panic!("{} defaults don't parse: {e}", block.kind));
            let parsed = parsed.as_object().unwrap();
            let keys: Vec<&str> = parsed.keys().map(String::as_str).collect();
            for key in &keys {
                assert!(
                    block.settings.iter().any(|s| s.key == *key),
                    "{} setting {key} isn't in the catalog",
                    block.kind
                );
            }
            for (key, value) in &defaults {
                assert!(same(&parsed[key], value), "{}.{key} default", block.kind);
            }
            // A setting the engine fills in by itself must default to the
            // same value here.
            for s in &block.settings {
                let mut without = defaults.clone();
                without.remove(s.key);
                if let Ok(parsed) = parse(block.kind, &without) {
                    let engine = parsed.get(s.key).cloned().unwrap_or(Value::Null);
                    assert!(
                        same(&engine, &s.default),
                        "{}.{}: engine default {engine}, catalog {}",
                        block.kind,
                        s.key,
                        s.default
                    );
                }
            }
        }
    }

    #[test]
    fn every_block_explains_itself() {
        let placeholder = |text: &str| -> Vec<(String, Option<String>, bool)> {
            let mut out = Vec::new();
            let mut rest = text;
            while let Some(start) = rest.find('{') {
                let end = rest[start..].find('}').expect("unclosed {") + start;
                let inner = &rest[start + 1..end];
                let (inner, fallback) = match inner.split_once('|') {
                    Some((i, _)) => (i, true),
                    None => (inner, false),
                };
                let (key, format) = match inner.split_once(':') {
                    Some((k, f)) => (k.to_string(), Some(f.to_string())),
                    None => (inner.to_string(), None),
                };
                out.push((key, format, fallback));
                rest = &rest[end + 1..];
            }
            out
        };

        for block in all() {
            assert!(block.watches.ends_with('.'), "{} watches", block.kind);
            assert!(!block.ports.is_empty(), "{} has no ports", block.kind);
            for s in &block.settings {
                assert!(
                    !s.label.is_empty() && !s.help.is_empty(),
                    "{}.{}",
                    block.kind,
                    s.key
                );
                if let Some(Reads { when, .. }) = s.reads.last() {
                    assert!(
                        matches!(when, When::Otherwise),
                        "{}.{} reads must end with Otherwise",
                        block.kind,
                        s.key
                    );
                }
            }
            let templates = block.ports.iter().map(|p| p.words).chain(block.stop);
            for words in templates {
                assert!(!words.is_empty(), "{} has a port with no words", block.kind);
                for (key, format, fallback) in placeholder(words) {
                    let s = block
                        .settings
                        .iter()
                        .find(|s| s.key == key)
                        .unwrap_or_else(|| {
                            panic!("{} words name unknown setting {key}", block.kind)
                        });
                    assert!(
                        matches!(format.as_deref(), None | Some("bars")),
                        "{}: unknown format in {words}",
                        block.kind
                    );
                    assert!(
                        !s.default.is_null() || fallback || !s.reads.is_empty(),
                        "{}.{key} can be empty, so {words} needs a fallback",
                        block.kind
                    );
                }
            }
            for series in &block.series {
                for level in &series.levels {
                    if let Level::Setting(key) | Level::Neg { neg: key } = level {
                        assert!(
                            block.settings.iter().any(|s| s.key == *key),
                            "{} level {key}",
                            block.kind
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn every_component_type_is_in_the_catalog() {
        // Exhaustive: a new `Component` variant doesn't compile until it's
        // named here, and in `names` below, which must all be in the catalog.
        #[allow(dead_code)]
        fn name(c: &Component) -> &'static str {
            match c {
                Component::TrendFollowing(_) => "TrendFollowing",
                Component::MeanReversion(_) => "MeanReversion",
                Component::Macd(_) => "Macd",
                Component::Donchian(_) => "Donchian",
                Component::MaFilter(_) => "MaFilter",
                Component::RsiReversion(_) => "RsiReversion",
                Component::NoiseArea(_) => "NoiseArea",
                Component::Momentum(_) => "Momentum",
                Component::EventWindow(_) => "EventWindow",
                Component::Bollinger(_) => "Bollinger",
                Component::Stochastic(_) => "Stochastic",
                Component::AdxFilter(_) => "AdxFilter",
                Component::Volatility(_) => "Volatility",
                Component::Vwap(_) => "Vwap",
                Component::OpeningRange(_) => "OpeningRange",
                Component::PivotPoints(_) => "PivotPoints",
                Component::Carry(_) => "Carry",
            }
        }
        let names = [
            "TrendFollowing",
            "MeanReversion",
            "Macd",
            "Donchian",
            "MaFilter",
            "RsiReversion",
            "NoiseArea",
            "Momentum",
            "EventWindow",
            "Bollinger",
            "Stochastic",
            "AdxFilter",
            "Volatility",
            "Vwap",
            "OpeningRange",
            "PivotPoints",
            "Carry",
        ];
        assert_eq!(all().len(), names.len());
        for n in names {
            assert!(block(n).is_some(), "{n} isn't in the catalog");
        }
    }
}
