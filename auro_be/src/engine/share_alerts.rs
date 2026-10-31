//! Share alerts: what a daily strategy assigned to a stock or ETF says
//! today, for a person to act on by hand at Wealthsimple. Nothing here
//! places an order.
//!
//! The decision follows `strategy::run_backtest` bar for bar, long only (a
//! share account can't short): while holding, the stop first, then the
//! time stop, then the exit rule; while not holding, the entry rule, with
//! the stop the backtest would have set. Today's bar is the day so far
//! (Questrade's quote 15 minutes before the close), so the alert can be
//! acted on before the close the backtest decided on.

use chrono::{DateTime, NaiveDate, Utc};
use chrono_tz::America::New_York;
use serde::Serialize;

use super::strategy::{compute_stop_price, EntrySignal, ExitSignal, Strategy};
use super::types::{Candle, Direction, OHLC};

/// A position the person logged from this assignment's alerts: the day it
/// was bought and the stop set then.
#[derive(Debug, Clone, Copy)]
pub struct Held {
    pub entry_day: NaiveDate,
    pub stop_price: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SellReason {
    /// The day's low reached the stop.
    Stop,
    /// Held as many days as the strategy allows.
    TimeStop,
    /// The strategy's exit rule.
    Rule,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum Decision {
    Buy {
        price: f64,
        stop_price: f64,
    },
    Sell {
        price: f64,
        reason: SellReason,
    },
    /// Holding, and nothing says sell.
    Hold {
        price: f64,
        stop_price: f64,
    },
    /// Not holding, and nothing says buy.
    Wait {
        price: f64,
    },
    /// The strategy can't decide on these bars (too few, or a block that
    /// can't compute for this market).
    Unready {
        why: String,
    },
}

/// The day so far as a bar stamped like the stored daily bars (midnight New
/// York), from the quote's open, high, low and latest price.
pub fn today_bar(day_open: DateTime<Utc>, open: f64, high: f64, low: f64, last: f64) -> Candle {
    Candle::from_trade_bar(
        day_open,
        OHLC {
            open,
            high: high.max(last),
            low: low.min(last),
            close: last,
        },
        0.0,
    )
}

/// Decide on `candles` (oldest first, ending with today's bar). `strategy`
/// is the long-only form (`pipeline::long_only`).
pub fn decide(strategy: &Strategy, candles: &[Candle], held: Option<&Held>) -> Decision {
    let Some(today) = candles.last() else {
        return Decision::Unready {
            why: "no daily bars".into(),
        };
    };
    let price = today.mid.close;
    let cap = strategy.granularity.buffer_capacity();
    let window = &candles[candles.len().saturating_sub(cap)..];

    if let Some(held) = held {
        if today.sl_check_price(Direction::Long) <= held.stop_price {
            return Decision::Sell {
                price,
                reason: SellReason::Stop,
            };
        }
        let days_held = candles
            .iter()
            .filter(|c| ny_day(c.time) > held.entry_day)
            .count();
        if strategy.max_hold_bars.is_some_and(|max| days_held >= max) {
            return Decision::Sell {
                price,
                reason: SellReason::TimeStop,
            };
        }
        return match strategy.compute_ports(window) {
            Some(ports) => match strategy.evaluate_exit(window, &ports, true) {
                ExitSignal::Exit => Decision::Sell {
                    price,
                    reason: SellReason::Rule,
                },
                ExitSignal::Hold => Decision::Hold {
                    price,
                    stop_price: held.stop_price,
                },
            },
            None => unready(strategy, candles.len()),
        };
    }

    let Some(ports) = strategy.compute_ports(window) else {
        return unready(strategy, candles.len());
    };
    match strategy.evaluate_entry(window, &ports) {
        EntrySignal::Long => match compute_stop_price(strategy, price, Direction::Long, window) {
            Some(stop_price) => Decision::Buy { price, stop_price },
            None => Decision::Unready {
                why: "the stop can't be set on these bars".into(),
            },
        },
        EntrySignal::Short | EntrySignal::None => Decision::Wait { price },
    }
}

fn unready(strategy: &Strategy, bars: usize) -> Decision {
    let need = strategy.warmup() + 1;
    Decision::Unready {
        why: if bars < need {
            format!("needs {need} daily bars, has {bars}")
        } else {
            "a block can't compute for this market".into()
        },
    }
}

fn ny_day(time: DateTime<Utc>) -> NaiveDate {
    time.with_timezone(&New_York).date_naive()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::strategy::run_backtest;
    use crate::engine::types::ExitReason;
    use chrono::{Duration, TimeZone};
    use serde_json::json;

    /// RSI(2) dip-buy, long only, a 3-day time stop and a wide ATR stop.
    fn dip_buy(max_hold: usize) -> Strategy {
        serde_json::from_value(json!({
            "version": "v1_composite",
            "strategy_id": null,
            "strategy_name": "test dip-buy",
            "instrument": "SPY",
            "granularity": "D",
            "components": {
                "r": {"type": "RsiReversion", "params": {"rsi_period": 2, "oversold": 20, "overbought": 80}}
            },
            "entry": {"long": "r.long"},
            "exit": {"long": "r.exit_long"},
            "stop": {"type": "FixedPct", "params": {"pct": -0.05}},
            "sizing": {"type": "RiskPct", "params": {"pct": 0.01}},
            "max_hold_bars": max_hold
        }))
        .unwrap()
    }

    fn bars(closes: &[f64]) -> Vec<Candle> {
        let start = Utc.with_ymd_and_hms(2026, 1, 5, 5, 0, 0).unwrap();
        closes
            .iter()
            .enumerate()
            .map(|(i, &c)| today_bar(start + Duration::days(i as i64), c, c, c, c))
            .collect()
    }

    /// A drift up with a sharp three-day drop at the end.
    fn closes_ending_in_a_dip() -> Vec<f64> {
        let mut closes: Vec<f64> = (0..40).map(|i| 100.0 + i as f64 * 0.3).collect();
        closes.extend([108.0, 104.0, 100.0]);
        closes
    }

    /// Every entry and exit the backtest makes over a choppy series, the
    /// alert makes on the same day: a buy with the same stop, a sell for the
    /// same reason.
    #[test]
    fn decides_as_the_backtest_does_on_every_day() {
        let strategy = dip_buy(4);
        let closes: Vec<f64> = (0..250)
            .map(|i| {
                100.0
                    + i as f64 * 0.05
                    + 6.0 * (i as f64 * 0.7).sin()
                    + 3.0 * (i as f64 * 0.31).cos()
            })
            .collect();
        let candles = bars(&closes);
        let trades = run_backtest(&candles, &strategy);
        assert!(trades.len() > 5, "the series should trade");

        let at = |time| candles.iter().position(|c| c.time == time).unwrap();
        for trade in &trades {
            let i = at(trade.entry_time);
            assert_eq!(
                decide(&strategy, &candles[..=i], None),
                Decision::Buy {
                    price: candles[i].mid.close,
                    stop_price: trade.stop_price
                }
            );
            let reason = match trade.exit_reason {
                ExitReason::StopLoss => SellReason::Stop,
                ExitReason::TimeStop => SellReason::TimeStop,
                ExitReason::TrendReversal => SellReason::Rule,
                _ => continue,
            };
            let held = Held {
                entry_day: ny_day(trade.entry_time),
                stop_price: trade.stop_price,
            };
            let j = at(trade.exit_time);
            assert_eq!(
                decide(&strategy, &candles[..=j], Some(&held)),
                Decision::Sell {
                    price: candles[j].mid.close,
                    reason
                }
            );
            for k in i + 1..j {
                assert!(matches!(
                    decide(&strategy, &candles[..=k], Some(&held)),
                    Decision::Hold { .. }
                ));
            }
        }
    }

    #[test]
    fn waits_when_the_backtest_would_not_enter() {
        let strategy = dip_buy(10);
        let candles = bars(&(0..40).map(|i| 100.0 + i as f64).collect::<Vec<_>>());
        assert!(matches!(
            decide(&strategy, &candles, None),
            Decision::Wait { .. }
        ));
    }

    #[test]
    fn sells_at_the_stop_before_anything_else() {
        let strategy = dip_buy(10);
        let candles = bars(&closes_ending_in_a_dip());
        let held = Held {
            entry_day: ny_day(candles[candles.len() - 2].time),
            stop_price: 101.0,
        };
        assert_eq!(
            decide(&strategy, &candles, Some(&held)),
            Decision::Sell {
                price: 100.0,
                reason: SellReason::Stop
            }
        );
    }

    #[test]
    fn sells_on_the_time_stop_after_max_hold_days() {
        let strategy = dip_buy(3);
        let candles = bars(&closes_ending_in_a_dip());
        let entry_day = ny_day(candles[candles.len() - 4].time);
        let held = Held {
            entry_day,
            stop_price: 50.0,
        };
        assert_eq!(
            decide(&strategy, &candles, Some(&held)),
            Decision::Sell {
                price: 100.0,
                reason: SellReason::TimeStop
            }
        );

        let one_day_less = Held {
            entry_day: ny_day(candles[candles.len() - 3].time),
            ..held
        };
        assert!(matches!(
            decide(&strategy, &candles, Some(&one_day_less)),
            Decision::Hold { .. }
        ));
    }

    #[test]
    fn sells_on_the_exit_rule() {
        let strategy = dip_buy(10);
        let mut closes = closes_ending_in_a_dip();
        closes.extend([104.0, 110.0]);
        let candles = bars(&closes);
        let held = Held {
            entry_day: ny_day(candles[candles.len() - 3].time),
            stop_price: 50.0,
        };
        assert_eq!(
            decide(&strategy, &candles, Some(&held)),
            Decision::Sell {
                price: 110.0,
                reason: SellReason::Rule
            }
        );
    }

    #[test]
    fn too_few_bars_says_how_many_it_needs() {
        let strategy = dip_buy(10);
        let candles = bars(&[100.0, 101.0]);
        assert!(matches!(
            decide(&strategy, &candles, None),
            Decision::Unready { why } if why.starts_with("needs")
        ));
    }

    #[test]
    fn today_bar_stretches_high_and_low_to_the_latest_price() {
        let day = Utc.with_ymd_and_hms(2026, 1, 5, 5, 0, 0).unwrap();
        let bar = today_bar(day, 10.0, 11.0, 9.5, 12.0);
        assert_eq!(
            (bar.mid.high, bar.mid.low, bar.mid.close),
            (12.0, 9.5, 12.0)
        );
        let bar = today_bar(day, 10.0, 11.0, 9.5, 9.0);
        assert_eq!(bar.mid.low, 9.0);
    }
}
