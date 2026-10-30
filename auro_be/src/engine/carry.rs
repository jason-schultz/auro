//! FX carry: for a pair BASE_QUOTE, the carry is the base currency's
//! central-bank policy rate minus the quote currency's, in percentage
//! points (USD 5.25% against JPY 0.10% is +5.15 for USD_JPY). `long`: the
//! carry is at least `min_spread` (holding the pair long earns the
//! difference); `short`: it is at most −`min_spread` (holding it short
//! earns). Between the two neither fires; with `min_spread` 0 and the rates
//! equal both fire, which the strategy reads as no signal.
//!
//! Rates come from the `policy_rates` table (BIS policy-rate change points),
//! the same rows the backtest's financing model uses. The rate for a bar is
//! the latest change dated at or before the New York date the bar opens on,
//! so a change is never seen before its effective date (and a daily bar,
//! which opens at 17:00 New York the day before its trading day, sees it a
//! day late rather than early).
//!
//! Candles alone don't carry rates, so whoever reads the strategy hands the
//! rates to the block once (`attach`): the pipeline from its financing model
//! (`pipeline::run_strategy`), the live evaluator and the preview from the
//! same table. A block without them, an instrument that isn't a currency
//! pair, or a date before a currency's first recorded rate can't compute:
//! the strategy has no signal on that bar, never a quiet "no".

use std::collections::HashMap;
use std::sync::Arc;

use chrono::NaiveDate;
use chrono_tz::America::New_York;
use serde::{Deserialize, Serialize};

use crate::engine::catalog::{port, Block, Level, Series, Setting};
use crate::engine::financing::PolicyRates;
use crate::engine::pipeline::{instrument_class, InstrumentClass};
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

/// A quarter of a percentage point: below that the two central banks are
/// effectively level (both near zero for much of 2016–2021), and a
/// zero-width threshold would flip the signal on rounding noise. OANDA's
/// financing markup (about 1 point a year on FX, `financing.rs`) means a
/// position only *collects* financing above roughly 1 point; the block
/// signals the direction of the carry, which is what the carry-trade
/// literature sorts on, not whether OANDA pays it.
fn default_min_spread() -> f64 {
    0.25
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct CarryParams {
    /// Smallest rate difference that counts, in percentage points.
    #[serde(default = "default_min_spread")]
    pub min_spread: f64,
    /// The pair's rates, handed over by `attach`. Not part of the settings.
    #[serde(skip)]
    pair: Option<Pair>,
}

#[derive(Debug, Clone)]
struct Pair {
    base: String,
    quote: String,
    rates: Arc<PolicyRates>,
}

/// The base and quote currencies of an FX pair (`"EUR_USD"` →
/// `("EUR", "USD")`), or why the instrument has no carry.
pub fn currencies(instrument: &str) -> Result<(&str, &str), String> {
    let is_currency = |c: &str| c.len() == 3 && c.chars().all(|ch| ch.is_ascii_uppercase());
    match (instrument_class(instrument), instrument.split_once('_')) {
        (InstrumentClass::FxMajor | InstrumentClass::FxCross, Some((base, quote)))
            if is_currency(base) && is_currency(quote) =>
        {
            Ok((base, quote))
        }
        _ => Err(format!(
            "{instrument} isn't a currency pair, so it has no interest-rate carry"
        )),
    }
}

impl CarryParams {
    /// Give the block the policy rates of `instrument`'s two currencies.
    pub(crate) fn attach(
        &mut self,
        instrument: &str,
        rates: &Arc<PolicyRates>,
    ) -> Result<(), String> {
        let (base, quote) = currencies(instrument)?;
        if let Some(missing) = [base, quote].into_iter().find(|c| !rates.knows(c)) {
            return Err(format!("no policy rate recorded for {missing}"));
        }
        self.pair = Some(Pair {
            base: base.to_string(),
            quote: quote.to_string(),
            rates: Arc::clone(rates),
        });
        Ok(())
    }

    /// The carry in percentage points for the newest bar.
    fn carry(&self, candles: &[Candle]) -> Option<f64> {
        let pair = self.pair.as_ref()?;
        let date = bar_date(candles.last()?);
        let base = pair.rates.rate_at(&pair.base, date)?;
        let quote = pair.rates.rate_at(&pair.quote, date)?;
        Some((base - quote) * 100.0)
    }
}

/// The New York date a bar opens on.
fn bar_date(candle: &Candle) -> NaiveDate {
    candle.time.with_timezone(&New_York).date_naive()
}

/// This block in the catalog (`engine::catalog`).
pub(crate) fn catalog() -> Block {
    Block {
        kind: "Carry",
        key: "c",
        name: "Interest-rate carry",
        watches: "The gap between the two currencies' central-bank interest rates, as it stood on each day. Holding the higher-rate currency against the lower one earns the gap, so money tends to flow that way. Currency pairs only.",
        settings: vec![Setting::float(
            "min_spread",
            "Smallest gap (points)",
            0.25,
            "In percentage points a year. A smaller gap counts as level and signals neither way. OANDA keeps about 1 point a year, so below that a position pays more than it earns.",
        )
        .at_least(0.0, "below 0 a long and a short would both fire on the same carry")],
        ports: vec![
            port("long", "the first currency's central-bank rate is at least {min_spread} percentage points above the second's (holding it earns)"),
            port("short", "the first currency's central-bank rate is at least {min_spread} percentage points below the second's (selling it short earns)"),
        ],
        series: vec![Series::panel(
            "carry",
            "Rate gap (percentage points)",
            vec![Level::Neg { neg: "min_spread" }, Level::At(0.0), Level::Setting("min_spread")],
        )],
        stop: None,
    }
}

impl Signaler for CarryParams {
    fn warmup(&self) -> usize {
        1
    }

    /// `long`: carry ≥ `min_spread`; `short`: carry ≤ −`min_spread`
    /// (inclusive: a threshold the user sets is met when reached).
    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        let carry = self.carry(candles)?;
        Some(HashMap::from([
            ("long".to_string(), carry >= self.min_spread),
            ("short".to_string(), carry <= -self.min_spread),
        ]))
    }

    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        self.carry(candles)
            .map(|c| HashMap::from([("carry".to_string(), c)]))
            .unwrap_or_default()
    }

    fn entry_reason(&self, candles: &[Candle], _direction: Direction) -> EntryReason {
        EntryReason::Indicator {
            name: "carry_pct_points",
            value: self.carry(candles).unwrap_or(0.0),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::{DateTime, TimeZone, Utc};

    fn d(y: i32, m: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, day).unwrap()
    }

    fn bar_at(time: DateTime<Utc>) -> Candle {
        Candle {
            time,
            mid: OHLC {
                open: 1.0,
                high: 1.0,
                low: 1.0,
                close: 1.0,
            },
            volume: 1,
            bid: None,
            ask: None,
        }
    }

    /// USD 5.00%; JPY 0.10% until 2024-03-19, then 0.25%.
    fn rates() -> Arc<PolicyRates> {
        Arc::new(PolicyRates::new(vec![
            ("USD".into(), d(2023, 7, 27), 0.05),
            ("JPY".into(), d(2016, 1, 1), 0.001),
            ("JPY".into(), d(2024, 3, 19), 0.0025),
        ]))
    }

    fn carry(min_spread: f64, instrument: &str) -> CarryParams {
        let mut block = CarryParams {
            min_spread,
            pair: None,
        };
        block.attach(instrument, &rates()).unwrap();
        block
    }

    #[test]
    fn a_higher_base_rate_is_a_long_carry() {
        // 12:00 UTC is 08:00 New York, same date: 5.00 − 0.10 = 4.90 points.
        let bars = [bar_at(Utc.with_ymd_and_hms(2024, 1, 10, 12, 0, 0).unwrap())];
        let block = carry(0.25, "USD_JPY");
        assert!((block.series(&bars)["carry"] - 4.9).abs() < 1e-9);
        let ports = block.compute(&bars).unwrap();
        assert!(ports["long"] && !ports["short"]);
    }

    #[test]
    fn the_inverse_pair_is_a_short_carry() {
        let bars = [bar_at(Utc.with_ymd_and_hms(2024, 1, 10, 12, 0, 0).unwrap())];
        // Not an OANDA pair, but two currencies all the same: 0.10 − 5.00.
        let ports = carry(0.25, "JPY_USD").compute(&bars).unwrap();
        assert!(ports["short"] && !ports["long"]);
    }

    #[test]
    fn a_threshold_above_the_carry_signals_neither_side() {
        let bars = [bar_at(Utc.with_ymd_and_hms(2024, 1, 10, 12, 0, 0).unwrap())];
        let ports = carry(5.0, "USD_JPY").compute(&bars).unwrap();
        assert!(!ports["long"] && !ports["short"]);
        // Exactly at the threshold counts.
        let ports = carry(4.9, "USD_JPY").compute(&bars).unwrap();
        assert!(ports["long"]);
    }

    #[test]
    fn a_rate_change_is_not_seen_before_its_effective_date() {
        let block = carry(0.25, "USD_JPY");
        // 2024-03-18 23:30 New York is 2024-03-19 03:30 UTC: still the 18th
        // in New York, so the old JPY rate (4.90 points).
        let eve = [bar_at(Utc.with_ymd_and_hms(2024, 3, 19, 3, 30, 0).unwrap())];
        assert!((block.series(&eve)["carry"] - 4.9).abs() < 1e-9);
        // 2024-03-19 09:30 New York: the new rate (4.75 points).
        let day = [bar_at(
            Utc.with_ymd_and_hms(2024, 3, 19, 13, 30, 0).unwrap(),
        )];
        assert!((block.series(&day)["carry"] - 4.75).abs() < 1e-9);
    }

    #[test]
    fn rates_dated_after_a_bar_do_not_change_it() {
        let bar = [bar_at(Utc.with_ymd_and_hms(2024, 1, 10, 12, 0, 0).unwrap())];
        let before = carry(0.25, "USD_JPY").series(&bar)["carry"];
        let mut later = CarryParams {
            min_spread: 0.25,
            pair: None,
        };
        let with_future = Arc::new(PolicyRates::new(vec![
            ("USD".into(), d(2023, 7, 27), 0.05),
            ("USD".into(), d(2024, 1, 11), 0.10),
            ("JPY".into(), d(2016, 1, 1), 0.001),
        ]));
        later.attach("USD_JPY", &with_future).unwrap();
        assert_eq!(later.series(&bar)["carry"], before);
    }

    #[test]
    fn before_the_first_recorded_rate_it_cannot_compute() {
        // USD's first change point is 2023-07-27.
        let bars = [bar_at(Utc.with_ymd_and_hms(2023, 7, 26, 12, 0, 0).unwrap())];
        assert!(carry(0.25, "USD_JPY").compute(&bars).is_none());
    }

    #[test]
    fn without_rates_it_cannot_compute() {
        let block = CarryParams {
            min_spread: 0.25,
            pair: None,
        };
        let bars = [bar_at(Utc.with_ymd_and_hms(2024, 1, 10, 12, 0, 0).unwrap())];
        assert!(block.compute(&bars).is_none());
    }

    #[test]
    fn non_fx_instruments_and_unknown_currencies_are_refused() {
        let mut block = CarryParams {
            min_spread: 0.25,
            pair: None,
        };
        assert!(block.attach("XAU_USD", &rates()).is_err());
        assert!(block.attach("SPX500_USD", &rates()).is_err());
        assert!(block.attach("AAPL", &rates()).is_err());
        let err = block.attach("EUR_USD", &rates()).unwrap_err();
        assert!(err.contains("EUR"), "{err}");
        assert!(block.pair.is_none());
    }

    #[test]
    fn the_default_threshold_is_a_quarter_point() {
        let block: CarryParams = serde_json::from_value(serde_json::json!({})).unwrap();
        assert_eq!(block.min_spread, 0.25);
    }
}
