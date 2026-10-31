//! Overnight financing for backtests.
//!
//! OANDA charges (or pays) financing on every position held across its 17:00
//! New York rollover: the interbank carry of the pair (base rate − quote rate)
//! less a markup, applied to notional per calendar day (so Friday → Monday
//! counts three days, matching OANDA's triple-rollover Wednesday in aggregate).
//! The backtest runner ignores this; `apply_costs` charges it after the
//! fact, trade by trade.
//!
//! That is OANDA's cost. A market traded elsewhere is charged its own
//! broker's (`BrokerCosts`, the `brokers` table via
//! `instruments.test_broker`): a cash account at Wealthsimple has no
//! overnight cost but a spread on every trade, and can't short. A market
//! with no broker isn't tested at all (`pipeline::require_brokers`); the
//! OANDA model below applies only where a market's broker says so (or, in
//! unit tests, where no brokers are loaded).
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
use std::sync::Arc;

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

/// Central-bank policy rates (`policy_rates`): each currency's change
/// points, ascending. The rate in force on a date is the latest change at
/// or before it. One table, read the same way by the financing model and by
/// the `Carry` block.
#[derive(Debug, Default, Clone)]
pub struct PolicyRates(HashMap<String, Series<f64>>);

impl PolicyRates {
    pub fn new(rows: Vec<(String, NaiveDate, f64)>) -> Self {
        let mut by_currency: HashMap<String, Series<f64>> = HashMap::new();
        for (currency, date, rate) in rows {
            by_currency.entry(currency).or_default().push((date, rate));
        }
        for s in by_currency.values_mut() {
            s.sort_by_key(|(d, _)| *d);
        }
        Self(by_currency)
    }

    /// Whether the table has any rate for `currency`.
    pub fn knows(&self, currency: &str) -> bool {
        self.0.get(currency).is_some_and(|s| !s.is_empty())
    }

    /// The rate in force for `currency` on `date` (annual fraction), or
    /// None before its first recorded change or for an unknown currency.
    pub fn rate_at(&self, currency: &str, date: NaiveDate) -> Option<f64> {
        self.0.get(currency).and_then(|s| latest_at(s, date))
    }
}

/// What holding overnight costs at a broker (`brokers.overnight_cost`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Overnight {
    /// OANDA's daily financing (this module's model).
    OandaFinancing,
    /// Nothing: shares owned outright in a cash account.
    None,
}

/// The costs a market's tests charge: its broker's (`brokers`), with the
/// market's own measured spread when it has one.
#[derive(Debug, Clone, PartialEq)]
pub struct BrokerCosts {
    /// The broker's name (`brokers.name`), for the results page.
    pub broker: String,
    pub overnight: Overnight,
    /// Round-trip spread per trade in basis points, or None to fill at the
    /// bars' own bid/ask (OANDA's bars carry them).
    pub spread_bps: Option<f64>,
    /// Charged on entry and again on exit, in basis points.
    pub commission_bps: f64,
    /// When false the strategy's short rules are skipped.
    pub can_short: bool,
}

#[derive(Debug, Default, Clone)]
pub struct FinancingModel {
    /// Policy-rate change points per currency.
    policy: Arc<PolicyRates>,
    /// Recorded OANDA (long, short) rates per instrument.
    recorded: HashMap<String, Series<(f64, f64)>>,
    /// Each market's broker costs, by every name it's known by.
    brokers: HashMap<String, BrokerCosts>,
    /// Cash dividends per share by ex-date, ascending, for each market
    /// whose dividend history has been fetched (none paid: an empty list).
    dividends: HashMap<String, Vec<(NaiveDate, f64)>>,
    /// Markets with no dividend history to fetch (Massive covers US listings
    /// only): the payments recorded from Questrade as they came, ascending,
    /// often none. Their tests run without the dividends before these.
    recorded_dividends: HashMap<String, Vec<(NaiveDate, f64)>>,
}

impl FinancingModel {
    pub fn new(
        policy: Vec<(String, NaiveDate, f64)>,
        recorded: Vec<(String, NaiveDate, f64, f64)>,
    ) -> Self {
        let mut model = Self {
            policy: Arc::new(PolicyRates::new(policy)),
            recorded: HashMap::new(),
            brokers: HashMap::new(),
            dividends: HashMap::new(),
            recorded_dividends: HashMap::new(),
        };
        for (instrument, date, long, short) in recorded {
            model
                .recorded
                .entry(instrument)
                .or_default()
                .push((date, (long, short)));
        }
        for s in model.recorded.values_mut() {
            s.sort_by_key(|(d, _)| *d);
        }
        model
    }

    /// The model with each market's broker costs, `(market name, costs)`.
    pub fn with_brokers(mut self, brokers: Vec<(String, BrokerCosts)>) -> Self {
        self.brokers = brokers.into_iter().collect();
        self
    }

    /// The model with each fetched market's dividends, `(market, [(ex-date,
    /// cash a share)])`; a market fetched with none paid has an empty list.
    pub fn with_dividends(mut self, dividends: Vec<(String, Vec<(NaiveDate, f64)>)>) -> Self {
        self.dividends = dividends
            .into_iter()
            .map(|(market, mut paid)| {
                paid.sort_by_key(|(d, _)| *d);
                (market, paid)
            })
            .collect();
        self
    }

    /// The model with the markets that have no dividend history to fetch,
    /// each with the payments recorded for it so far (`recorded_dividends`).
    pub fn with_recorded_dividends(
        mut self,
        recorded: Vec<(String, Vec<(NaiveDate, f64)>)>,
    ) -> Self {
        self.recorded_dividends = recorded
            .into_iter()
            .map(|(market, mut paid)| {
                paid.sort_by_key(|(d, _)| *d);
                (market, paid)
            })
            .collect();
        self
    }

    /// For a market with no dividend history to fetch: Some(the first
    /// recorded ex-date, or None before any). None for every other market.
    pub fn dividends_recorded_since(&self, market: &str) -> Option<Option<NaiveDate>> {
        self.recorded_dividends
            .get(market)
            .map(|paid| paid.first().map(|(d, _)| *d))
    }

    /// What's known of `market`'s dividends: None when they were never
    /// fetched; Some(None) when it pays none; Some(Some(date)) when the
    /// record starts at that ex-date (earlier payments are unknown).
    pub fn dividends_from(&self, market: &str) -> Option<Option<NaiveDate>> {
        self.dividends
            .get(market)
            .map(|paid| paid.first().map(|(d, _)| *d))
    }

    /// `market`'s dividends, `(ex-date, cash a share)` ascending: its
    /// fetched history, or for a market with none to fetch, what has been
    /// recorded; empty when it pays none or nothing is known.
    pub fn dividends(&self, market: &str) -> &[(NaiveDate, f64)] {
        self.dividends
            .get(market)
            .or_else(|| self.recorded_dividends.get(market))
            .map_or(&[], Vec::as_slice)
    }

    /// Whether `market` holds shares outright (its broker charges no
    /// overnight cost), so its dividends are paid to a long.
    pub fn owns_shares(&self, market: &str) -> bool {
        self.costs_for(market)
            .is_some_and(|c| c.overnight == Overnight::None)
    }

    /// Dividends paid to a long `trade` in `market`, as a return on its
    /// entry: every ex-date after the day it was bought, up to and
    /// including the day it was sold (it held the shares at the close
    /// before each).
    fn dividends_paid(&self, market: &str, trade: &Trade) -> f64 {
        let paid = self.dividends(market);
        if trade.direction != Direction::Long || trade.entry_price <= 0.0 {
            return 0.0;
        }
        let bought = trade.entry_time.with_timezone(&New_York).date_naive();
        let sold = trade.exit_time.with_timezone(&New_York).date_naive();
        paid.iter()
            .filter(|(ex, _)| *ex > bought && *ex <= sold)
            .map(|(_, cash)| cash / trade.entry_price)
            .sum()
    }

    /// The broker costs `market` is tested with, if any are loaded for it.
    pub fn costs_for(&self, market: &str) -> Option<&BrokerCosts> {
        self.brokers.get(market)
    }

    /// Whether `market`'s broker lets a strategy short it (yes when no
    /// broker is loaded for it: OANDA's model).
    pub fn can_short(&self, market: &str) -> bool {
        self.costs_for(market).is_none_or(|c| c.can_short)
    }

    /// The policy rates the model is built on (for the `Carry` block).
    pub fn policy_rates(&self) -> &Arc<PolicyRates> {
        &self.policy
    }

    fn policy_rate(&self, currency: &str, date: NaiveDate) -> f64 {
        self.policy.rate_at(currency, date).unwrap_or(0.0)
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

/// Charge each trade's costs into its `pnl_percent`: overnight financing
/// where the market's broker charges OANDA's (or none is loaded: OANDA's
/// model), and a fixed spread and commission per round trip where it sets
/// them. Shares held outright are paid their dividends instead.
pub fn apply_costs(trades: &mut [Trade], instrument: &str, model: &FinancingModel) {
    let costs = model.costs_for(instrument);
    let overnight = costs.map_or(Overnight::OandaFinancing, |c| c.overnight);
    let per_trade = costs.map_or(0.0, |c| {
        (c.spread_bps.unwrap_or(0.0) + 2.0 * c.commission_bps) / 10_000.0
    });
    for trade in trades.iter_mut() {
        match overnight {
            Overnight::OandaFinancing => {
                trade.pnl_percent += model.trade_financing(instrument, trade);
            }
            Overnight::None => trade.pnl_percent += model.dividends_paid(instrument, trade),
        }
        trade.pnl_percent -= per_trade;
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
    fn apply_costs_charges_financing_in_place() {
        let mut trades = vec![trade(Direction::Long, utc(8, 18), utc(9, 18))];
        trades[0].pnl_percent = 0.01;
        apply_costs(&mut trades, "EUR_USD", &model());
        assert!((trades[0].pnl_percent - (0.01 - 0.03 / 365.0)).abs() < 1e-12);
    }

    fn wealthsimple(spread_bps: f64) -> BrokerCosts {
        BrokerCosts {
            broker: "wealthsimple".into(),
            overnight: Overnight::None,
            spread_bps: Some(spread_bps),
            commission_bps: 0.0,
            can_short: false,
        }
    }

    #[test]
    fn a_cash_account_pays_its_spread_and_no_overnight_cost() {
        let model = model().with_brokers(vec![("SPY".into(), wealthsimple(10.0))]);
        // Held a month: OANDA's model would charge every night.
        let mut trades = vec![trade(Direction::Long, utc(1, 18), utc(30, 18))];
        trades[0].pnl_percent = 0.01;
        apply_costs(&mut trades, "SPY", &model);
        assert!((trades[0].pnl_percent - (0.01 - 0.001)).abs() < 1e-12);
        assert!(!model.can_short("SPY"));
    }

    #[test]
    fn a_long_held_over_an_ex_date_is_paid_its_dividend() {
        let model = FinancingModel::default()
            .with_brokers(vec![("SPY".into(), wealthsimple(0.0))])
            .with_dividends(vec![(
                "SPY".into(),
                vec![(d(2024, 7, 5), 2.0), (d(2024, 7, 20), 3.0)],
            )]);
        // Bought Jul 1 at 100, sold the 5th: paid the 5th's (held at the
        // close before it), not the 20th's.
        let mut held = trade(Direction::Long, utc(1, 18), utc(5, 18));
        held.entry_price = 100.0;
        // Bought on the ex-date itself: too late for it.
        let mut late = trade(Direction::Long, utc(5, 18), utc(10, 18));
        late.entry_price = 100.0;
        let mut trades = vec![held, late];
        apply_costs(&mut trades, "SPY", &model);
        assert!((trades[0].pnl_percent - 0.02).abs() < 1e-12);
        assert!(trades[1].pnl_percent.abs() < 1e-12);
        assert_eq!(model.dividends_from("SPY"), Some(Some(d(2024, 7, 5))));
    }

    #[test]
    fn dividends_never_fetched_are_unknown_and_none_paid_is_known() {
        let model = FinancingModel::default().with_dividends(vec![("GLD".into(), vec![])]);
        assert_eq!(model.dividends_from("GLD"), Some(None));
        assert_eq!(model.dividends_from("SPY"), None);
    }

    #[test]
    fn a_market_without_dividend_history_is_paid_what_was_recorded() {
        let model = FinancingModel::default()
            .with_brokers(vec![("XIU.TO".into(), wealthsimple(0.0))])
            .with_recorded_dividends(vec![
                ("XIU.TO".into(), vec![(d(2024, 7, 5), 1.0)]),
                ("SDE.TO".into(), vec![]),
            ]);
        // Recorded, not history: it's paid, but the record isn't where its
        // tests start.
        assert_eq!(model.dividends_from("XIU.TO"), None);
        assert_eq!(
            model.dividends_recorded_since("XIU.TO"),
            Some(Some(d(2024, 7, 5)))
        );
        assert_eq!(model.dividends_recorded_since("SDE.TO"), Some(None));
        assert_eq!(model.dividends_recorded_since("SPY"), None);

        let mut trades = vec![trade(Direction::Long, utc(1, 18), utc(30, 18))];
        trades[0].entry_price = 100.0;
        trades[0].exit_time =
            chrono::TimeZone::with_ymd_and_hms(&Utc, 2024, 7, 10, 18, 0, 0).unwrap();
        trades[0].entry_time =
            chrono::TimeZone::with_ymd_and_hms(&Utc, 2024, 7, 1, 18, 0, 0).unwrap();
        apply_costs(&mut trades, "XIU.TO", &model);
        assert!((trades[0].pnl_percent - 0.01).abs() < 1e-12);
    }

    #[test]
    fn commission_is_paid_on_the_way_in_and_out() {
        let broker = BrokerCosts {
            commission_bps: 5.0,
            ..wealthsimple(0.0)
        };
        let model = FinancingModel::default().with_brokers(vec![("XIU".into(), broker)]);
        let mut trades = vec![trade(Direction::Long, utc(8, 18), utc(9, 18))];
        apply_costs(&mut trades, "XIU", &model);
        assert!((trades[0].pnl_percent + 0.001).abs() < 1e-12);
    }

    #[test]
    fn an_oanda_market_keeps_oandas_financing_and_its_bid_ask() {
        let oanda = BrokerCosts {
            broker: "oanda".into(),
            overnight: Overnight::OandaFinancing,
            spread_bps: None,
            commission_bps: 0.0,
            can_short: true,
        };
        let with = model().with_brokers(vec![("EUR_USD".into(), oanda)]);
        let mut a = vec![trade(Direction::Long, utc(8, 18), utc(9, 18))];
        let mut b = a.clone();
        apply_costs(&mut a, "EUR_USD", &with);
        apply_costs(&mut b, "EUR_USD", &model());
        assert_eq!(a[0].pnl_percent, b[0].pnl_percent);
        assert!(with.can_short("EUR_USD"));
    }
}
