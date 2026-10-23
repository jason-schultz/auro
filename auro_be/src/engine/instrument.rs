//! The security master (`instruments`, Opus migration
//! `20261023160000_create_instruments`): one row per listing, the name each
//! vendor knows it by, and the feeds that store data for it. Tables that
//! still carry an instrument as text are being rekeyed onto
//! [`InstrumentId`]; until that lands the vendor columns here are the
//! bridge between the id and the text the older tables hold. The feed
//! flags are Opus's to read (it schedules the feeds); Rust only stores.

use std::fmt;

use serde::{Deserialize, Serialize};

/// Primary key of `instruments`. A newtype so an instrument id can never
/// be handed where a trade id or a Questrade symbol id was meant.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, sqlx::Type)]
#[sqlx(transparent)]
#[serde(transparent)]
pub struct InstrumentId(pub i64);

impl fmt::Display for InstrumentId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// What kind of thing the listing is. The OANDA classes match
/// `validation_thresholds.instrument_class` and `instrument_to_class`;
/// `equity` and `etf` are the listed-market additions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "varchar", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum AssetClass {
    FxMajor,
    FxCross,
    Metal,
    Commodity,
    Index,
    Bond,
    Equity,
    Etf,
}

impl AssetClass {
    pub fn as_str(self) -> &'static str {
        match self {
            AssetClass::FxMajor => "fx_major",
            AssetClass::FxCross => "fx_cross",
            AssetClass::Metal => "metal",
            AssetClass::Commodity => "commodity",
            AssetClass::Index => "index",
            AssetClass::Bond => "bond",
            AssetClass::Equity => "equity",
            AssetClass::Etf => "etf",
        }
    }
}

/// One listing as the master stores it.
#[derive(Debug, Clone, PartialEq, Serialize, sqlx::FromRow)]
pub struct Instrument {
    pub id: InstrumentId,
    /// Bare listing symbol: `RY`, `XIU`, `SPY`, `EUR_USD`.
    pub symbol: String,
    /// `OANDA`, `TSX`, `TSXV`, `CNSX`, `NYSE`, `NASDAQ`, …; `US` until the
    /// Questrade enrich pass names the real one.
    pub exchange: String,
    pub currency: String,
    pub asset_class: AssetClass,
    pub figi: Option<String>,
    pub active: bool,
    pub oanda_symbol: Option<String>,
    /// Questrade spelling (`RY.TO`, `SPY`).
    pub questrade_symbol: Option<String>,
    /// Questrade's numeric id, recorded on first lookup.
    pub questrade_symbol_id: Option<i64>,
    pub massive_ticker: Option<String>,
    pub feed_questrade_bars: bool,
    pub feed_massive_daily: bool,
    pub feed_options_chain: bool,
}

impl Instrument {
    /// `TSX:RY` — unambiguous in logs where the bare symbol is not.
    pub fn label(&self) -> String {
        format!("{}:{}", self.exchange, self.symbol)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asset_class_strings_match_the_threshold_classes() {
        for (class, text) in [
            (AssetClass::FxMajor, "fx_major"),
            (AssetClass::FxCross, "fx_cross"),
            (AssetClass::Metal, "metal"),
            (AssetClass::Commodity, "commodity"),
            (AssetClass::Index, "index"),
            (AssetClass::Bond, "bond"),
            (AssetClass::Equity, "equity"),
            (AssetClass::Etf, "etf"),
        ] {
            assert_eq!(class.as_str(), text);
            assert_eq!(serde_json::to_value(class).unwrap(), text);
        }
    }

    #[test]
    fn instrument_id_serialises_as_a_bare_number() {
        assert_eq!(serde_json::to_value(InstrumentId(42)).unwrap(), 42);
        assert_eq!(InstrumentId(7).to_string(), "7");
    }
}
