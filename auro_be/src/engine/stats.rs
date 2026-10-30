use std::collections::BTreeMap;

use chrono::{DateTime, Datelike, Duration, NaiveDate, Utc, Weekday};

use crate::engine::live::sizing::MAX_POSITION_PCT_OF_NAV;
use crate::engine::pipeline::span;
use crate::engine::portfolio::{simulate, Play};
use crate::engine::strategy::SizingConfig;
use crate::engine::types::{Candle, Trade};

/// Trading days a year, for annualizing a daily Sharpe.
const TRADING_DAYS: f64 = 252.0;

/// How a strategy sizes its trades (`SizingConfig::RiskPct`), for the
/// account figures: each trade risks `risk_pct` of the account against its
/// stop, its position capped at `max_position_pct` of the account.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AccountSizing {
    pub risk_pct: f64,
    pub max_position_pct: f64,
}

impl AccountSizing {
    pub fn of(sizing: &SizingConfig) -> Self {
        let SizingConfig::RiskPct {
            pct,
            max_notional_pct,
        } = sizing;
        Self {
            risk_pct: *pct,
            max_position_pct: max_notional_pct.unwrap_or(MAX_POSITION_PCT_OF_NAV),
        }
    }
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct BacktestStats {
    /// Every trade's return added up, each on a whole-account position (1
    /// unit of notional per unit of account). Not what the account makes:
    /// the pipeline's gates were set on this figure, so it stays as is.
    pub total_return: f64,
    pub win_rate: f64,
    pub avg_win: f64,
    pub avg_loss: f64,
    /// The worst fall (≤ 0) of `total_return`'s running sum from its high,
    /// valued at every bar's close: open trades count at that close.
    pub max_drawdown: f64,
    /// What the account would have made: the trades one after another,
    /// each sized as live sizes it (`AccountSizing`), compounded.
    pub account_return: f64,
    /// The account's worst fall from its high on the same basis (≤ 0),
    /// valued at every bar's close the same way.
    pub account_max_drawdown: f64,
    /// The risk per trade the account figures assume.
    pub account_risk_pct: f64,
    /// Per trade: the average trade over how much trades vary. Only
    /// meaningful with the trade count (`pipeline::t_stat`).
    pub sharpe_ratio: f64,
    /// The standard Sharpe, a year's worth (`annual_sharpe`): comparable
    /// across strategies and with what charting tools report.
    pub annual_sharpe: f64,
    pub num_trades: usize,
    /// Set when judged on calendar-month account returns
    /// (`judge_by_months`, a ranked basket): how many months, and then
    /// `sharpe_ratio`/`annual_sharpe` are the months', not the trades'.
    pub num_months: Option<usize>,
}

/// The drawdowns and the account's growth, valued at every bar
/// (`portfolio::simulate`): what a backtest's trades alone can't tell.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Marked {
    /// `BacktestStats::max_drawdown` (≤ 0).
    pub max_drawdown: f64,
    pub account_return: f64,
    /// `BacktestStats::account_max_drawdown` (≤ 0).
    pub account_max_drawdown: f64,
}

/// Calculates the backtest statistics for one market's trades.
///
/// `bars` are the bars the trades were made on (their first and last bar
/// set the stretch for the annual Sharpe). The drawdowns are valued at
/// every bar's close, open trades included (`portfolio::mark_return`):
/// a trade held for months that was 10% down midway shows that 10%, even
/// if it closed flat.
pub fn calculate_backtest_stats(
    trades: &[Trade],
    bars: &[Candle],
    sizing: AccountSizing,
) -> BacktestStats {
    let (from, to) = span(bars);
    let play = Play {
        key: String::new(),
        instrument: String::new(),
        risk_pct: sizing.risk_pct,
        max_position_pct: sizing.max_position_pct,
        breaker_exempt: true,
        trades: trades.to_vec(),
        bars,
    };
    let outcome = simulate(&[&play], None, from, to);
    let marked = Marked {
        max_drawdown: -outcome.summed_max_drawdown,
        account_return: outcome.total_return,
        account_max_drawdown: -outcome.max_drawdown,
    };
    stats_with(trades, from, to, sizing, marked)
}

/// The backtest statistics of `trades` traded between `from` and `to`,
/// with drawdowns and growth already valued at every bar (`marked`).
pub fn stats_with(
    trades: &[Trade],
    from: DateTime<Utc>,
    to: DateTime<Utc>,
    sizing: AccountSizing,
    marked: Marked,
) -> BacktestStats {
    if trades.is_empty() {
        return BacktestStats {
            total_return: 0.0,
            win_rate: 0.0,
            avg_win: 0.0,
            avg_loss: 0.0,
            max_drawdown: 0.0,
            account_return: 0.0,
            account_max_drawdown: 0.0,
            account_risk_pct: sizing.risk_pct,
            sharpe_ratio: 0.0,
            annual_sharpe: 0.0,
            num_trades: 0,
            num_months: None,
        };
    }

    let winners = trades
        .iter()
        .filter(|t| t.pnl_percent > 0.0)
        .map(|t| t.pnl_percent)
        .collect::<Vec<_>>();
    let losers = trades
        .iter()
        .filter(|t| t.pnl_percent < 0.0)
        .map(|t| t.pnl_percent)
        .collect::<Vec<_>>();

    let total_return = trades.iter().map(|t| t.pnl_percent).sum::<f64>();
    let win_rate =
        trades.iter().filter(|t| t.pnl_percent > 0.0).count() as f64 / trades.len() as f64;
    let avg_win = if winners.is_empty() {
        0.0
    } else {
        winners.iter().sum::<f64>() / winners.len() as f64
    };
    let avg_loss = if losers.is_empty() {
        0.0
    } else {
        losers.iter().sum::<f64>() / losers.len() as f64
    };

    let pnls: Vec<f64> = trades.iter().map(|t| t.pnl_percent).collect();

    BacktestStats {
        total_return,
        win_rate,
        avg_win,
        avg_loss,
        max_drawdown: marked.max_drawdown,
        account_return: marked.account_return,
        account_max_drawdown: marked.account_max_drawdown,
        account_risk_pct: sizing.risk_pct,
        sharpe_ratio: sharpe_of(&pnls),
        annual_sharpe: annual_sharpe(trades, from, to),
        num_trades: trades.len(),
        num_months: None,
    }
}

/// Months in a year, for annualizing a monthly Sharpe.
const MONTHS: f64 = 12.0;

impl BacktestStats {
    /// Judge on the account's calendar-month returns instead of its trades
    /// (a ranked basket): the Sharpe is per month, the annual Sharpe a
    /// year of months, and the luck test counts months (`num_months`).
    pub fn judge_by_months(&mut self, monthly: &[f64]) {
        self.sharpe_ratio = sharpe_of(monthly);
        self.annual_sharpe = self.sharpe_ratio * MONTHS.sqrt();
        self.num_months = Some(monthly.len());
    }

    /// How many returns the per-period Sharpe is over: months when judged
    /// by months, else trades.
    pub fn periods(&self) -> usize {
        self.num_months.unwrap_or(self.num_trades)
    }
}

/// Mean over the (population) standard deviation; 0 when flat or empty.
fn sharpe_of(returns: &[f64]) -> f64 {
    if returns.is_empty() {
        return 0.0;
    }
    let n = returns.len() as f64;
    let mean = returns.iter().sum::<f64>() / n;
    let std_dev = (returns.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / n).sqrt();
    if std_dev == 0.0 {
        0.0
    } else {
        mean / std_dev
    }
}

/// The standard (annualized) Sharpe from daily returns: each trade's return
/// is booked on the UTC day it closes, every weekday from `from` to `to`
/// without one counts as a flat day, and the daily mean over the daily
/// standard deviation (population, like the per-trade figure) is scaled by
/// √252. Days out of the market count, so a strategy that trades rarely
/// isn't flattered. 0 with under two days or no variation.
pub fn annual_sharpe(trades: &[Trade], from: DateTime<Utc>, to: DateTime<Utc>) -> f64 {
    let returns = trades.iter().map(|t| (t.exit_time, t.pnl_percent));
    annual_sharpe_of(&daily_returns(returns, from, to))
}

/// Returns booked on the UTC day they close, every weekday from `from` to
/// `to` present (0 when nothing closed that day).
pub fn daily_returns(
    returns: impl IntoIterator<Item = (DateTime<Utc>, f64)>,
    from: DateTime<Utc>,
    to: DateTime<Utc>,
) -> BTreeMap<NaiveDate, f64> {
    let mut days: BTreeMap<NaiveDate, f64> = BTreeMap::new();
    let (first, last) = (from.date_naive(), to.date_naive());
    let mut day = first;
    while day <= last {
        if !matches!(day.weekday(), Weekday::Sat | Weekday::Sun) {
            days.insert(day, 0.0);
        }
        day += Duration::days(1);
    }
    for (at, r) in returns {
        *days.entry(at.date_naive()).or_insert(0.0) += r;
    }
    days
}

/// The annual Sharpe of a daily return series (`daily_returns`).
pub fn annual_sharpe_of(days: &BTreeMap<NaiveDate, f64>) -> f64 {
    let n = days.len() as f64;
    if n < 2.0 {
        return 0.0;
    }
    let mean = days.values().sum::<f64>() / n;
    let std_dev = (days.values().map(|r| (r - mean).powi(2)).sum::<f64>() / n).sqrt();
    if std_dev == 0.0 {
        0.0
    } else {
        mean / std_dev * TRADING_DAYS.sqrt()
    }
}

#[cfg(test)]
mod tests {
    use chrono::Utc;

    use crate::engine::types::{Direction, EntryReason, ExitReason, Trade, OHLC};

    use super::*;

    const SIZING: AccountSizing = AccountSizing {
        risk_pct: 0.01,
        max_position_pct: 0.15,
    };

    fn utc(day: &str) -> chrono::DateTime<Utc> {
        chrono::DateTime::parse_from_rfc3339(&format!("{day}T00:00:00Z"))
            .unwrap()
            .with_timezone(&Utc)
    }

    fn dummy_trade(pnl: f64) -> Trade {
        Trade {
            direction: Direction::Long,
            pnl_percent: pnl,
            entry_price: 1.0,
            exit_price: 1.0,
            entry_time: utc("2026-01-05"),
            exit_time: utc("2026-01-05"),
            entry_reason: EntryReason::CrossAbove {
                fast_ma: 0.0,
                slow_ma: 0.0,
            },
            exit_reason: ExitReason::TrendReversal,
            stop_price: 0.0,
        }
    }

    /// A bar at `time` closing at `close`.
    fn bar(time: chrono::DateTime<Utc>, close: f64) -> Candle {
        Candle {
            time,
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

    /// Flat bars at every trade's entry and exit: the trades are valued
    /// only when they open and close.
    fn bars_for(trades: &[Trade]) -> Vec<Candle> {
        let mut times: Vec<_> = trades
            .iter()
            .flat_map(|t| [t.entry_time, t.exit_time])
            .collect();
        times.sort();
        times.dedup();
        times.into_iter().map(|t| bar(t, 1.0)).collect()
    }

    /// `pnls` as trades one a day from Jan 5 2026, each held a day.
    fn daily_trades(pnls: &[f64]) -> Vec<Trade> {
        pnls.iter()
            .enumerate()
            .map(|(i, &pnl)| {
                let entry = utc("2026-01-05") + Duration::days(2 * i as i64);
                Trade {
                    entry_time: entry,
                    exit_time: entry + Duration::days(1),
                    ..dummy_trade(pnl)
                }
            })
            .collect()
    }

    #[test]
    fn test_calculate_backtest_stats_empty() {
        let stats = calculate_backtest_stats(&[], &[], SIZING);
        assert_eq!(stats.total_return, 0.0);
        assert_eq!(stats.win_rate, 0.0);
        assert_eq!(stats.avg_win, 0.0);
        assert_eq!(stats.avg_loss, 0.0);
        assert_eq!(stats.max_drawdown, 0.0);
        assert_eq!(stats.sharpe_ratio, 0.0);
        assert_eq!(stats.num_trades, 0);
        assert_eq!(stats.num_months, None);
    }

    #[test]
    fn test_calculate_backtest_stats() {
        let trades = daily_trades(&[10.0, -5.0, 20.0]);
        let stats = calculate_backtest_stats(&trades, &bars_for(&trades), SIZING);
        assert_eq!(stats.total_return, 25.0);
        assert_eq!(stats.win_rate, 2.0 / 3.0);
        assert_eq!(stats.avg_win, 15.0);
        assert_eq!(stats.avg_loss, -5.0);
        // 10 → 5: half of the 1 + 10 high.
        assert!((stats.max_drawdown + 5.0 / 11.0).abs() < 1e-12);
        assert!(stats.sharpe_ratio > 0.0);
        assert_eq!(stats.num_trades, 3);
    }

    #[test]
    fn a_held_trade_that_dips_10_percent_and_recovers_shows_a_10_percent_drop() {
        // Long at 100 for eight bars: down to 90, back to 100, closed flat.
        let closes = [100.0, 97.0, 94.0, 91.0, 90.0, 92.0, 95.0, 98.0, 100.0];
        let bars: Vec<Candle> = closes
            .iter()
            .enumerate()
            .map(|(i, &c)| bar(utc("2026-01-05") + Duration::days(i as i64), c))
            .collect();
        let trade = Trade {
            entry_price: 100.0,
            exit_price: 100.0,
            pnl_percent: 0.0,
            entry_time: bars[0].time,
            exit_time: bars[8].time,
            // A 10% stop at 10% risk: the whole account in it.
            stop_price: 90.0,
            ..dummy_trade(0.0)
        };
        let sizing = AccountSizing {
            risk_pct: 0.10,
            max_position_pct: 1.0,
        };
        let stats = calculate_backtest_stats(&[trade], &bars, sizing);
        assert_eq!(stats.total_return, 0.0);
        assert!((stats.max_drawdown + 0.10).abs() < 1e-12);
        assert!((stats.account_max_drawdown + 0.10).abs() < 1e-12);
        assert!(stats.account_return.abs() < 1e-12);
    }

    fn closed_on(day: &str, pnl: f64) -> Trade {
        let at = chrono::DateTime::parse_from_rfc3339(&format!("{day}T20:00:00Z"))
            .unwrap()
            .with_timezone(&Utc);
        Trade {
            exit_time: at,
            entry_time: at,
            ..dummy_trade(pnl)
        }
    }

    #[test]
    fn annual_sharpe_counts_flat_weekdays_and_skips_weekends() {
        // Mon 2026-01-05 to Fri 2026-01-16: ten weekdays, two trades.
        let trades = vec![
            closed_on("2026-01-06", 0.02),
            closed_on("2026-01-13", -0.01),
        ];
        let got = annual_sharpe(&trades, utc("2026-01-05"), utc("2026-01-16"));

        let days = [0.0, 0.02, 0.0, 0.0, 0.0, 0.0, -0.01, 0.0, 0.0, 0.0];
        let mean = days.iter().sum::<f64>() / 10.0;
        let sd = (days.iter().map(|d| (d - mean).powi(2)).sum::<f64>() / 10.0).sqrt();
        assert!((got - mean / sd * 252f64.sqrt()).abs() < 1e-12);
    }

    #[test]
    fn annual_sharpe_is_zero_without_variation_or_days() {
        assert_eq!(
            annual_sharpe(&[], utc("2026-01-05"), utc("2026-01-16")),
            0.0
        );
        assert_eq!(
            annual_sharpe(&[], utc("2026-01-05"), utc("2026-01-05")),
            0.0
        );
    }

    #[test]
    fn a_steady_small_edge_reads_as_a_normal_annual_sharpe() {
        // Twenty trades a year at +0.5% / -0.4% alternating: a modest edge.
        // Per trade that is about 0.1; a year of it is roughly 0.5, not 0.1.
        let mut trades = Vec::new();
        let mut day = utc("2025-01-06");
        for i in 0..20 {
            day += chrono::Duration::days(14);
            let pnl = if i % 2 == 0 { 0.005 } else { -0.004 };
            trades.push(Trade {
                exit_time: day,
                entry_time: day,
                ..dummy_trade(pnl)
            });
        }
        let mut bars = bars_for(&trades);
        bars.insert(0, bar(utc("2025-01-06"), 1.0));
        let stats = calculate_backtest_stats(&trades, &bars, SIZING);
        assert!(stats.sharpe_ratio < 0.15);
        assert!(stats.annual_sharpe > 0.3 && stats.annual_sharpe < 0.6);
    }

    /// A trade entered at 100 with its stop at `stop`, returning `pnl`.
    fn stopped_at(stop: f64, pnl: f64) -> Trade {
        Trade {
            entry_price: 100.0,
            stop_price: stop,
            ..dummy_trade(pnl)
        }
    }

    fn one_after_another(trades: impl IntoIterator<Item = Trade>) -> Vec<Trade> {
        trades
            .into_iter()
            .enumerate()
            .map(|(i, t)| {
                let entry = utc("2026-01-05") + Duration::days(2 * i as i64);
                Trade {
                    entry_time: entry,
                    exit_time: entry + Duration::days(1),
                    ..t
                }
            })
            .collect()
    }

    #[test]
    fn the_account_compounds_each_trade_at_its_sized_share() {
        // 1% risk, 2% stop: half the account in the trade. +10% then −10%:
        // 1.05 × 0.95 = 0.9975, against +0% added up.
        let sizing = AccountSizing {
            risk_pct: 0.01,
            max_position_pct: 1.0,
        };
        let trades = one_after_another([stopped_at(98.0, 0.10), stopped_at(98.0, -0.10)]);
        let stats = calculate_backtest_stats(&trades, &bars_for(&trades), sizing);
        assert_eq!(stats.total_return, 0.0);
        assert!((stats.account_return - (1.05 * 0.95 - 1.0)).abs() < 1e-12);
        assert!((stats.account_max_drawdown - (-0.05)).abs() < 1e-12);
        assert_eq!(stats.account_risk_pct, 0.01);
    }

    #[test]
    fn the_account_position_is_capped() {
        // A 0.1% stop would put 10× the account in; the 15% cap holds it.
        let trades = one_after_another([stopped_at(99.9, 0.10)]);
        let stats = calculate_backtest_stats(&trades, &bars_for(&trades), SIZING);
        assert!((stats.account_return - 0.015).abs() < 1e-12);
    }

    #[test]
    fn a_run_of_losses_that_sums_past_minus_100_percent_is_not_below_nothing() {
        // Twelve −12% trades add up to −144%; at a whole account each the
        // account is left with 0.88^12 of itself, not a negative balance.
        let trades = one_after_another((0..12).map(|_| stopped_at(88.0, -0.12)));
        let sizing = AccountSizing {
            risk_pct: 0.12,
            max_position_pct: 1.0,
        };
        let stats = calculate_backtest_stats(&trades, &bars_for(&trades), sizing);
        assert!((stats.total_return - (-1.44)).abs() < 1e-9);
        assert!((stats.account_return - (0.88_f64.powi(12) - 1.0)).abs() < 1e-12);
        assert!(stats.account_max_drawdown > -1.0);
    }

    #[test]
    fn judged_by_months_the_sharpe_and_luck_test_count_months() {
        let trades = daily_trades(&[0.01, -0.005, 0.02]);
        let mut stats = calculate_backtest_stats(&trades, &bars_for(&trades), SIZING);
        assert_eq!(stats.periods(), 3);
        let months = [0.02, -0.01, 0.03, 0.0];
        stats.judge_by_months(&months);
        assert_eq!(stats.num_months, Some(4));
        assert_eq!(stats.periods(), 4);
        assert_eq!(stats.num_trades, 3);
        let mean = 0.04 / 4.0;
        let sd = (months.iter().map(|m| (m - mean).powi(2)).sum::<f64>() / 4.0).sqrt();
        assert!((stats.sharpe_ratio - mean / sd).abs() < 1e-12);
        assert!((stats.annual_sharpe - mean / sd * 12f64.sqrt()).abs() < 1e-12);
    }
}
