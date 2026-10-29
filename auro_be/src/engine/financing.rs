//! Overnight financing for backtests.
//!
//! OANDA charges (or pays) financing on every position held across its 17:00
//! New York rollover: the interbank carry of the pair (base rate − quote rate)
//! less a markup, applied to notional per calendar day (so Friday → Monday
//! counts three days, matching OANDA's triple-rollover Wednesday in aggregate).
//! The backtest runner ignores this; `apply_financing` charges it after the
//! fact, trade by trade.
//!
//! Two sources, best available first:
//!   1. OANDA's own per-instrument long/short rates, recorded daily into
//!      `instrument_financing` by Opus's FinancingSnapshotWorker. Used for any
//!      rollover at or after the first recorded date.
//!   2. Before that: central-bank policy rates (`policy_rates`, BIS series)
//!      plus a per-class markup calibrated against OANDA's live rates on
//!      2026-10-16 — about 1.0%/yr on FX, 1.2% on metals, 2.5% on indices,
//!      bonds and commodities. Index and metal CFDs earn nothing on the base
//!      side, so a long pays the quote-currency rate. Bond and commodity CFDs
//!      finance off yield-minus-repo and the futures basis respectively, which
//!      have no history here, so their carry is taken as zero (markup only).
//!
//! Rates are annual fractions; positive means the position earns.

use std::collections::HashMap;

use chrono::{DateTime, Duration, NaiveDate, Utc};
use chrono_tz::America::New_York;

use crate::engine::pipeline::{instrument_class, InstrumentClass};
use crate::engine::types::{Direction, Trade};

/// Annual markup OANDA adds over the interbank carry, per instrument class
/// (calibrated 2026-10-16; see module docs).
fn markup(class: InstrumentClass) -> f64 {
    match class {
        InstrumentClass::FxMajor | InstrumentClass::FxCross => 0.010,
        InstrumentClass::Metal => 0.012,
        InstrumentClass::Commodity | InstrumentClass::Index | InstrumentClass::Bond => 0.025,
    }
}

/// Date key of the rollover a timestamp falls under: the 17:00 New York
/// boundary, so 16:59 belongs to the previous day's session.
fn rollover_date(t: DateTime<Utc>) -> NaiveDate {
    (t.with_timezone(&New_York) - Duration::hours(17)).date_naive()
}

/// Latest value in an ascending-by-date series at or before `date`.
fn latest_at<T: Copy>(series: &[(NaiveDate, T)], date: NaiveDate) -> Option<T> {
    let idx = series.partition_point(|(d, _)| *d <= date);
    (idx > 0).then(|| series[idx - 1].1)
}

/// A date-stamped series, ascending by date.
type Series<T> = Vec<(NaiveDate, T)>;

#[derive(Debug, Default, Clone)]
pub struct FinancingModel {
    /// Policy-rate change points per currency.
    policy: HashMap<String, Series<f64>>,
    /// Recorded OANDA (long, short) rates per instrument.
    recorded: HashMap<String, Series<(f64, f64)>>,
}

impl FinancingModel {
    pub fn new(
        policy: Vec<(String, NaiveDate, f64)>,
        recorded: Vec<(String, NaiveDate, f64, f64)>,
    ) -> Self {
        let mut model = Self::default();
        for (currency, date, rate) in policy {
            model.policy.entry(currency).or_default().push((date, rate));
        }
        for (instrument, date, long, short) in recorded {
            model
                .recorded
                .entry(instrument)
                .or_default()
                .push((date, (long, short)));
        }
        for s in model.policy.values_mut() {
            s.sort_by_key(|(d, _)| *d);
        }
        for s in model.recorded.values_mut() {
            s.sort_by_key(|(d, _)| *d);
        }
        model
    }

    fn policy_rate(&self, currency: &str, date: NaiveDate) -> f64 {
        self.policy
            .get(currency)
            .and_then(|s| latest_at(s, date))
            .unwrap_or(0.0)
    }

    /// Annual rate earned (positive) or paid (negative) for holding
    /// `direction` in `instrument` across the rollover on `date`.
    pub fn annual_rate(&self, instrument: &str, direction: Direction, date: NaiveDate) -> f64 {
        if let Some((long, short)) = self
            .recorded
            .get(instrument)
            .and_then(|s| latest_at(s, date))
        {
            return match direction {
                Direction::Long => long,
                Direction::Short => short,
            };
        }

        let class = instrument_class(instrument);
        let (base, quote) = instrument.split_once('_').unwrap_or((instrument, ""));
        let carry = match class {
            InstrumentClass::FxMajor | InstrumentClass::FxCross => {
                self.policy_rate(base, date) - self.policy_rate(quote, date)
            }
            InstrumentClass::Metal | InstrumentClass::Index => -self.policy_rate(quote, date),
            InstrumentClass::Commodity | InstrumentClass::Bond => 0.0,
        };
        let sign = match direction {
            Direction::Long => 1.0,
            Direction::Short => -1.0,
        };
        sign * carry - markup(class)
    }

    /// Financing over a trade's life as a fraction of notional: one day's rate
    /// for every calendar day whose rollover the position was held across.
    pub fn trade_financing(&self, instrument: &str, trade: &Trade) -> f64 {
        let first = rollover_date(trade.entry_time);
        let last = rollover_date(trade.exit_time);
        let mut total = 0.0;
        let mut day = first + Duration::days(1);
        while day <= last {
            total += self.annual_rate(instrument, trade.direction, day) / 365.0;
            day += Duration::days(1);
        }
        total
    }
}

/// Charge financing into each trade's `pnl_percent`.
pub fn apply_financing(trades: &mut [Trade], instrument: &str, model: &FinancingModel) {
    for trade in trades.iter_mut() {
        trade.pnl_percent += model.trade_financing(instrument, trade);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::{EntryReason, ExitReason};
    use chrono::TimeZone;

    fn d(y: i32, m: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, day).unwrap()
    }

    /// Policy model: USD 4%, EUR 2% from 2020.
    fn model() -> FinancingModel {
        FinancingModel::new(
            vec![
                ("USD".into(), d(2020, 1, 1), 0.04),
                ("EUR".into(), d(2020, 1, 1), 0.02),
            ],
            vec![],
        )
    }

    fn trade(direction: Direction, entry: DateTime<Utc>, exit: DateTime<Utc>) -> Trade {
        Trade {
            direction,
            entry_price: 1.0,
            exit_price: 1.0,
            entry_time: entry,
            exit_time: exit,
            pnl_percent: 0.0,
            entry_reason: EntryReason::CrossAbove {
                fast_ma: 0.0,
                slow_ma: 0.0,
            },
            exit_reason: ExitReason::TrendReversal,
            stop_price: 0.0,
        }
    }

    // July: New York is UTC−4, so the 17:00 rollover is 21:00Z.
    fn utc(day: u32, hour: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2024, 7, day, hour, 0, 0).unwrap()
    }

    #[test]
    fn intraday_trade_pays_nothing() {
        // Monday 10:00 → 16:00 New York, never crossing 17:00.
        let t = trade(Direction::Long, utc(8, 14), utc(8, 20));
        assert_eq!(model().trade_financing("EUR_USD", &t), 0.0);
    }

    #[test]
    fn fx_long_pays_negative_carry_plus_markup_per_rollover() {
        // Monday 14:00 → Tuesday 14:00 NY: one rollover. Long EUR/USD earns
        // 2% and pays 4% → −2% carry, −1% markup → −3%/yr for one day.
        let t = trade(Direction::Long, utc(8, 18), utc(9, 18));
        let got = model().trade_financing("EUR_USD", &t);
        assert!((got - (-0.03 / 365.0)).abs() < 1e-12, "{got}");
    }

    #[test]
    fn fx_short_earns_carry_less_markup() {
        let t = trade(Direction::Short, utc(8, 18), utc(9, 18));
        let got = model().trade_financing("EUR_USD", &t);
        assert!((got - (0.02 - 0.01) / 365.0).abs() < 1e-12, "{got}");
    }

    #[test]
    fn weekend_hold_counts_three_days() {
        // Friday 14:00 → Monday 14:00 NY crosses Fri, Sat and Sun rollovers.
        let t = trade(Direction::Long, utc(12, 18), utc(15, 18));
        let got = model().trade_financing("EUR_USD", &t);
        assert!((got - 3.0 * (-0.03 / 365.0)).abs() < 1e-12, "{got}");
    }

    #[test]
    fn rollover_boundary_is_17_00_new_york() {
        // Entry 16:59 NY, exit 17:01 NY the same day: one rollover crossed.
        let entry = Utc.with_ymd_and_hms(2024, 7, 8, 20, 59, 0).unwrap();
        let exit = Utc.with_ymd_and_hms(2024, 7, 8, 21, 1, 0).unwrap();
        assert_ne!(
            model().trade_financing("EUR_USD", &trade(Direction::Long, entry, exit)),
            0.0
        );
        // Entry 17:01, exit 16:59 next day: none.
        let entry = Utc.with_ymd_and_hms(2024, 7, 8, 21, 1, 0).unwrap();
        let exit = Utc.with_ymd_and_hms(2024, 7, 9, 20, 59, 0).unwrap();
        assert_eq!(
            model().trade_financing("EUR_USD", &trade(Direction::Long, entry, exit)),
            0.0
        );
    }

    #[test]
    fn index_long_pays_quote_rate_plus_index_markup() {
        let t = trade(Direction::Long, utc(8, 18), utc(9, 18));
        let got = model().trade_financing("SPX500_USD", &t);
        assert!((got - (-0.04 - 0.025) / 365.0).abs() < 1e-12, "{got}");
    }

    #[test]
    fn bonds_and_commodities_pay_markup_only() {
        let t = trade(Direction::Short, utc(8, 18), utc(9, 18));
        let m = model();
        for inst in ["USB10Y_USD", "WTICO_USD"] {
            let got = m.trade_financing(inst, &t);
            assert!((got - (-0.025 / 365.0)).abs() < 1e-12, "{inst} {got}");
        }
    }

    #[test]
    fn policy_rate_in_force_is_the_latest_change_at_or_before_the_date() {
        let m = FinancingModel::new(
            vec![
                ("USD".into(), d(2020, 1, 1), 0.01),
                ("USD".into(), d(2024, 7, 10), 0.05),
            ],
            vec![],
        );
        // Rollover of Jul 9 (before the change) vs Jul 10 (on it).
        assert_eq!(
            m.annual_rate("XAU_USD", Direction::Long, d(2024, 7, 9)),
            -0.01 - 0.012
        );
        assert_eq!(
            m.annual_rate("XAU_USD", Direction::Long, d(2024, 7, 10)),
            -0.05 - 0.012
        );
    }

    #[test]
    fn recorded_oanda_rate_overrides_the_policy_model_from_its_first_date() {
        let m = FinancingModel::new(
            vec![
                ("USD".into(), d(2020, 1, 1), 0.04),
                ("EUR".into(), d(2020, 1, 1), 0.02),
            ],
            vec![("EUR_USD".into(), d(2024, 7, 9), -0.0245, 0.0042)],
        );
        assert_eq!(
            m.annual_rate("EUR_USD", Direction::Long, d(2024, 7, 8)),
            -0.03
        );
        assert_eq!(
            m.annual_rate("EUR_USD", Direction::Long, d(2024, 7, 9)),
            -0.0245
        );
        assert_eq!(
            m.annual_rate("EUR_USD", Direction::Short, d(2024, 7, 20)),
            0.0042
        );
    }

    #[test]
    fn apply_financing_adjusts_pnl_in_place() {
        let mut trades = vec![trade(Direction::Long, utc(8, 18), utc(9, 18))];
        trades[0].pnl_percent = 0.01;
        apply_financing(&mut trades, "EUR_USD", &model());
        assert!((trades[0].pnl_percent - (0.01 - 0.03 / 365.0)).abs() < 1e-12);
    }
}
