//! Opening-range breakout: the high and low of the first `minutes` of the US
//! session (from 09:30 New York). Once that range is set, `breakout_long` /
//! `breakout_short`: the close is above its high / below its low (strict);
//! `inside`: neither. `session_close`: the bar closes at or after the session
//! close (or before the open), so a day trade can always exit. Intraday bars
//! only.
//!
//! `first_bar_up` / `first_bar_down`: the opening range closed above / below
//! where it opened (the 09:30 open against the close of its last bar; equal
//! is neither). They fire once a session, on the close of the range's last
//! bar, so an entry fills at that close: the next bar's open, where
//! Zarattini, Barbon & Aziz (2023) enter in the first bar's direction. They
//! need the session's 09:30 bar; without it they don't fire.
//!
//! Optional, each off by default so saved strategies behave as before:
//! - `first_breakout_only`: the breakout ports fire only on the session's
//!   first bar that closes outside the range (either side). Blocks don't see
//!   positions, so this is "first breakout only", not "one trade a session":
//!   the two give the same trades unless another rule blocks that first
//!   breakout, in which case no later breakout trades that day.
//! - `no_entry_before_close`: minutes. The four entry ports above don't fire
//!   on a bar that closes this close to the session close or later (0: only
//!   the closing bar itself), so no trade opens just to be closed at 16:00.
//!
//! `stop_price` (for `StopConfig::FromComponent`): the far side of the range,
//! the low for a long and the high for a short, once the range is complete.
//! None when the decision bar's close is already past it (a stop on the
//! wrong side of the entry).

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::engine::catalog::{port, Block, Series, Setting, When};
use crate::engine::indicators::{self, OpeningRange};
use crate::engine::session::{self, BarClock, SESSION_OPEN_MIN};
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

fn default_minutes() -> i64 {
    30
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct OpeningRangeParams {
    #[serde(default = "default_minutes")]
    pub minutes: i64,
    /// Breakout ports fire only on the session's first breakout bar.
    #[serde(default)]
    pub first_breakout_only: bool,
    /// No entry port fires on a bar closing within this many minutes of the
    /// session close. None: off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub no_entry_before_close: Option<i64>,
}

impl OpeningRangeParams {
    fn range_bars(&self, clock: &BarClock) -> usize {
        (self.minutes / clock.bar_minutes).max(1) as usize
    }

    /// The range, once today's session has run past it.
    fn range(&self, candles: &[Candle], clock: &BarClock) -> Option<OpeningRange> {
        let bars = self.range_bars(clock);
        let today = session::today(candles);
        (today.len() > bars)
            .then(|| indicators::opening_range(today, bars))
            .flatten()
    }

    /// The range from the close of its last bar on.
    fn complete_range(&self, candles: &[Candle], clock: &BarClock) -> Option<OpeningRange> {
        let bars = self.range_bars(clock);
        let today = session::today(candles);
        (today.len() >= bars)
            .then(|| indicators::opening_range(today, bars))
            .flatten()
    }

    /// On the close of the range's last bar: whether the range closed above
    /// (Some(true)) or below (Some(false)) the session's 09:30 open. None on
    /// any other bar, without a 09:30 bar, or when it closed where it opened.
    fn first_bar_direction(&self, candles: &[Candle], clock: &BarClock) -> Option<bool> {
        let bars = self.range_bars(clock);
        let today = session::today(candles);
        let first = today.first()?;
        if today.len() != bars || session::ny_open(first).1 != SESSION_OPEN_MIN {
            return None;
        }
        let (open, close) = (first.mid.open, today.last()?.mid.close);
        (close != open).then_some(close > open)
    }

    /// Whether an earlier bar today, after the range, closed outside it.
    fn broke_out_before(&self, candles: &[Candle], clock: &BarClock, r: &OpeningRange) -> bool {
        let bars = self.range_bars(clock);
        let today = session::today(candles);
        today[bars.min(today.len())..today.len().saturating_sub(1)]
            .iter()
            .any(|c| c.mid.close > r.high || c.mid.close < r.low)
    }

    /// Too close to the session close for a new entry.
    fn entries_closed(&self, clock: &BarClock) -> bool {
        self.no_entry_before_close
            .is_some_and(|m| clock.close_min >= clock.session_close_min - m)
    }
}

/// This block in the catalog (`engine::catalog`).
pub(crate) fn catalog() -> Block {
    Block {
        kind: "OpeningRange",
        key: "or",
        name: "Opening range",
        watches: "The high and low of the first minutes after the US open (09:30 New York). Breaking out of that early range often sets the direction for the day. Intraday bars only.",
        settings: vec![
            Setting::int(
                "minutes",
                "First minutes",
                30,
                "Longer makes a wider range, so fewer but bigger breakouts. 5 with 5-minute bars makes the range the first bar alone.",
            ),
            Setting::bool(
                "first_breakout_only",
                "First breakout only",
                false,
                "Yes: only the day's first close outside the range counts, so a breakout trades at most once a day. If another rule blocks that first one, nothing trades later that day.",
            )
            .reads(vec![
                (When::Is(true.into()), " for the first time that day"),
                (When::Otherwise, ""),
            ]),
            Setting::int(
                "no_entry_before_close",
                "No new trades in the last (minutes)",
                Value::Null,
                "Leave empty for no limit. 0 stops a trade opening on the closing bar itself; 15 stops any in the last quarter hour. Closing a trade is never blocked.",
            )
            .at_least(0.0, "a negative guard never blocks anything, the same as none")
            .reads(vec![
                (When::Above(0.0), ", but not in the last {} minutes before the close"),
                (When::Is(0.into()), ", but not on the closing bar"),
                (When::Otherwise, ""),
            ]),
        ],
        ports: vec![
            port("breakout_long", "the price breaks above the high of the first {minutes} minutes after the US open{first_breakout_only}{no_entry_before_close}"),
            port("breakout_short", "the price breaks below the low of the first {minutes} minutes after the US open{first_breakout_only}{no_entry_before_close}"),
            port("inside", "the price is still inside the range of the first {minutes} minutes after the US open"),
            port("session_close", "the US session ends (16:00 New York)"),
            port("first_bar_up", "the first {minutes} minutes after the US open end above the 09:30 open (decided as they end){no_entry_before_close}"),
            port("first_bar_down", "the first {minutes} minutes after the US open end below the 09:30 open (decided as they end){no_entry_before_close}"),
        ],
        series: vec![
            Series::price("high", "Opening range high"),
            Series::price("low", "Opening range low"),
        ],
        stop: Some("the other side of the opening range (its low for a buy, its high for a short)"),
    }
}

impl Signaler for OpeningRangeParams {
    fn warmup(&self) -> usize {
        2
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        let clock = BarClock::of(candles)?;
        let close = candles.last()?.mid.close;
        let (mut long, mut short, inside) = match self.range(candles, &clock) {
            Some(r) => {
                let first =
                    !self.first_breakout_only || !self.broke_out_before(candles, &clock, &r);
                (
                    first && close > r.high,
                    first && close < r.low,
                    close <= r.high && close >= r.low,
                )
            }
            None => (false, false, false),
        };
        let direction = self.first_bar_direction(candles, &clock);
        let (mut up, mut down) = (direction == Some(true), direction == Some(false));
        if self.entries_closed(&clock) {
            (long, short, up, down) = (false, false, false, false);
        }
        Some(HashMap::from([
            ("breakout_long".to_string(), long),
            ("breakout_short".to_string(), short),
            ("inside".to_string(), inside),
            ("session_close".to_string(), clock.is_session_close()),
            ("first_bar_up".to_string(), up),
            ("first_bar_down".to_string(), down),
        ]))
    }

    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        BarClock::of(candles)
            .and_then(|clock| self.range(candles, &clock))
            .map(|r| HashMap::from([("high".to_string(), r.high), ("low".to_string(), r.low)]))
            .unwrap_or_default()
    }

    fn entry_reason(&self, candles: &[Candle], direction: Direction) -> EntryReason {
        let range = BarClock::of(candles).and_then(|clock| self.complete_range(candles, &clock));
        EntryReason::Indicator {
            name: "opening_range_edge",
            value: range.map_or(0.0, |r| match direction {
                Direction::Long => r.high,
                Direction::Short => r.low,
            }),
        }
    }

    fn stop_price(&self, candles: &[Candle], direction: Direction) -> Option<f64> {
        let clock = BarClock::of(candles)?;
        let r = self.complete_range(candles, &clock)?;
        let close = candles.last()?.mid.close;
        match direction {
            Direction::Long => (close > r.low).then_some(r.low),
            Direction::Short => (close < r.high).then_some(r.high),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::strategy::{run_backtest, Strategy};
    use crate::engine::types::{ExitReason, OHLC};
    use chrono::{DateTime, Duration, TimeZone, Utc};

    fn bar(time: DateTime<Utc>, high: f64, low: f64, close: f64) -> Candle {
        ohlc(time, close, high, low, close)
    }

    fn ohlc(time: DateTime<Utc>, open: f64, high: f64, low: f64, close: f64) -> Candle {
        Candle {
            time,
            mid: OHLC {
                open,
                high,
                low,
                close,
            },
            volume: 10,
            bid: None,
            ask: None,
        }
    }

    fn params(minutes: i64) -> OpeningRangeParams {
        OpeningRangeParams {
            minutes,
            first_breakout_only: false,
            no_entry_before_close: None,
        }
    }

    /// 09:30 New York on Monday 2026-01-05 (14:30 UTC).
    fn open_time() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 1, 5, 14, 30, 0).unwrap()
    }

    /// Friday's last two M5 bars (15:50 and 15:55 New York), so a session's
    /// first bar already reads as a 5-minute bar.
    fn friday_close() -> Vec<Candle> {
        let t = Utc.with_ymd_and_hms(2026, 1, 2, 20, 50, 0).unwrap();
        vec![
            bar(t, 100.0, 100.0, 100.0),
            bar(t + Duration::minutes(5), 100.0, 100.0, 100.0),
        ]
    }

    /// Six M5 bars from 09:30 New York (14:30 UTC on Monday 2026-01-05).
    fn morning(last_close: f64) -> Vec<Candle> {
        let open = open_time();
        let mut candles: Vec<Candle> = (0..6)
            .map(|i| bar(open + Duration::minutes(5 * i), 101.0, 99.0, 100.0))
            .collect();
        candles.push(bar(
            open + Duration::minutes(30),
            last_close,
            last_close,
            last_close,
        ));
        candles
    }

    /// Monday's session in M5 bars from 09:30, the first six inside 99–101,
    /// every later one closing at `after`.
    fn whole_day(after: f64) -> Vec<Candle> {
        let open = open_time();
        (0..78)
            .map(|i| {
                let close = if i < 6 { 100.0 } else { after };
                bar(
                    open + Duration::minutes(5 * i),
                    close.max(101.0),
                    close.min(99.0),
                    close,
                )
            })
            .collect()
    }

    #[test]
    fn closing_above_the_first_half_hour_is_a_breakout() {
        let ports = params(30).compute(&morning(102.0)).unwrap();
        assert!(ports["breakout_long"] && !ports["breakout_short"] && !ports["inside"]);
    }

    #[test]
    fn nothing_breaks_out_before_the_range_is_set() {
        let candles = morning(102.0);
        let ports = params(30).compute(&candles[..3]).unwrap();
        assert!(!ports["breakout_long"] && !ports["inside"]);
    }

    #[test]
    fn saved_settings_read_with_every_new_option_off() {
        let p: OpeningRangeParams =
            serde_json::from_value(serde_json::json!({"minutes": 30})).unwrap();
        assert!(!p.first_breakout_only);
        assert_eq!(p.no_entry_before_close, None);
        // Written back out, the off switch stays out of the settings.
        let written = serde_json::to_value(&p).unwrap();
        assert!(written.get("no_entry_before_close").is_none());
        // Every bar of a day that breaks out at 10:00 and stays out: the
        // breakout fires on every post-range bar, including the closing one.
        let day = whole_day(102.0);
        for end in 7..=day.len() {
            let ports = p.compute(&day[..end]).unwrap();
            assert!(ports["breakout_long"], "bar {end}");
        }
        assert!(p.compute(&day).unwrap()["session_close"]);
    }

    #[test]
    fn the_first_bar_closing_up_signals_up_on_its_own_close() {
        // 09:30 bar: opens 100, closes 101.
        let mut candles = friday_close();
        candles.push(ohlc(open_time(), 100.0, 101.5, 99.5, 101.0));
        let ports = params(5).compute(&candles).unwrap();
        assert!(ports["first_bar_up"] && !ports["first_bar_down"]);
        // The range isn't "past" yet, so no breakout on the same bar.
        assert!(!ports["breakout_long"]);
        // Once only: the next bar doesn't fire again.
        candles.push(bar(open_time() + Duration::minutes(5), 102.0, 101.0, 101.8));
        let ports = params(5).compute(&candles).unwrap();
        assert!(!ports["first_bar_up"] && !ports["first_bar_down"]);
    }

    #[test]
    fn the_first_bar_closing_down_signals_down_and_a_flat_one_neither() {
        let mut down = friday_close();
        down.push(ohlc(open_time(), 100.0, 100.5, 98.5, 99.0));
        let ports = params(5).compute(&down).unwrap();
        assert!(ports["first_bar_down"] && !ports["first_bar_up"]);

        let mut flat = friday_close();
        flat.push(ohlc(open_time(), 100.0, 100.5, 99.5, 100.0));
        let ports = params(5).compute(&flat).unwrap();
        assert!(!ports["first_bar_down"] && !ports["first_bar_up"]);
    }

    #[test]
    fn a_longer_range_reads_its_direction_from_the_open_to_its_last_close() {
        // 15 minutes = three M5 bars: open 100 → last close 100.4.
        let mut candles = friday_close();
        let t = open_time();
        candles.push(ohlc(t, 100.0, 100.5, 99.0, 99.2));
        candles.push(ohlc(t + Duration::minutes(5), 99.2, 100.0, 99.0, 99.8));
        let ports = params(15).compute(&candles).unwrap();
        assert!(
            !ports["first_bar_up"],
            "not yet: the range has one bar to go"
        );
        candles.push(ohlc(t + Duration::minutes(10), 99.8, 100.6, 99.7, 100.4));
        let ports = params(15).compute(&candles).unwrap();
        assert!(ports["first_bar_up"]);
    }

    #[test]
    fn without_the_0930_bar_there_is_no_first_bar_direction() {
        let mut candles = friday_close();
        candles.push(ohlc(
            open_time() + Duration::minutes(5),
            100.0,
            101.5,
            99.5,
            101.0,
        ));
        let ports = params(5).compute(&candles).unwrap();
        assert!(!ports["first_bar_up"] && !ports["first_bar_down"]);
    }

    #[test]
    fn first_breakout_only_fires_on_the_first_bar_outside_the_range() {
        let p = OpeningRangeParams {
            first_breakout_only: true,
            ..params(30)
        };
        let mut candles = morning(102.0);
        assert!(p.compute(&candles).unwrap()["breakout_long"]);
        // A second bar above the range: no longer the first breakout.
        candles.push(bar(
            open_time() + Duration::minutes(35),
            103.0,
            102.0,
            103.0,
        ));
        let ports = p.compute(&candles).unwrap();
        assert!(!ports["breakout_long"]);
        assert!(params(30).compute(&candles).unwrap()["breakout_long"]);
        // Nor does a later break of the other side count.
        candles.push(bar(open_time() + Duration::minutes(40), 98.0, 97.0, 97.5));
        assert!(!p.compute(&candles).unwrap()["breakout_short"]);
        assert!(params(30).compute(&candles).unwrap()["breakout_short"]);
    }

    #[test]
    fn first_breakout_only_ignores_bars_back_inside_the_range() {
        let p = OpeningRangeParams {
            first_breakout_only: true,
            ..params(30)
        };
        // 10:00 bar closes inside (100), 10:05 bar is the first one out.
        let mut candles = morning(100.0);
        candles.push(bar(open_time() + Duration::minutes(35), 98.5, 98.0, 98.5));
        assert!(p.compute(&candles).unwrap()["breakout_short"]);
    }

    #[test]
    fn no_entry_before_close_silences_entries_near_the_close() {
        let p = OpeningRangeParams {
            no_entry_before_close: Some(10),
            ..params(30)
        };
        let day = whole_day(102.0);
        // Bar 75 opens 15:40 and closes 15:45: still open for entries.
        assert!(p.compute(&day[..75]).unwrap()["breakout_long"]);
        // Bar 76 closes 15:50, ten minutes before the close: no entries.
        let ports = p.compute(&day[..76]).unwrap();
        assert!(!ports["breakout_long"]);
        // Exits are untouched: the closing bar still says the session ended.
        let last = p.compute(&day).unwrap();
        assert!(!last["breakout_long"] && last["session_close"]);
    }

    #[test]
    fn no_entry_before_close_zero_only_silences_the_closing_bar() {
        let p = OpeningRangeParams {
            no_entry_before_close: Some(0),
            ..params(30)
        };
        let day = whole_day(102.0);
        assert!(p.compute(&day[..77]).unwrap()["breakout_long"]);
        assert!(!p.compute(&day).unwrap()["breakout_long"]);
    }

    #[test]
    fn no_entry_before_close_also_silences_the_first_bar_direction() {
        // Friday 2026-11-27 closes at 13:00. A 205-minute range ends with
        // the bar closing 12:55, inside a 10-minute guard.
        let p = OpeningRangeParams {
            no_entry_before_close: Some(10),
            ..params(205)
        };
        let open = Utc.with_ymd_and_hms(2026, 11, 27, 14, 30, 0).unwrap();
        let mut candles: Vec<Candle> = (0..41)
            .map(|i| ohlc(open + Duration::minutes(5 * i), 100.0, 101.0, 99.0, 100.0))
            .collect();
        candles.last_mut().unwrap().mid.close = 100.5;
        let ports = p.compute(&candles).unwrap();
        assert!(!ports["first_bar_up"]);
        assert!(params(205).compute(&candles).unwrap()["first_bar_up"]);
    }

    #[test]
    fn the_stop_is_the_far_side_of_the_range() {
        let candles = morning(102.0);
        let p = params(30);
        assert_eq!(p.stop_price(&candles, Direction::Long), Some(99.0));
        // A short with the price above the range high has no valid stop there.
        assert_eq!(p.stop_price(&candles, Direction::Short), None);
        let below = morning(98.0);
        assert_eq!(p.stop_price(&below, Direction::Short), Some(101.0));
        // Before the range is complete there is no stop.
        assert_eq!(p.stop_price(&candles[..3], Direction::Long), None);
    }

    #[test]
    fn the_stop_is_ready_on_the_first_bar_direction_signal() {
        let mut candles = friday_close();
        candles.push(ohlc(open_time(), 100.0, 101.5, 99.5, 101.0));
        assert_eq!(params(5).stop_price(&candles, Direction::Long), Some(99.5));
    }

    /// The paper's day: enter in the first 5-minute bar's direction at the
    /// next open, stop at the far side of that bar, out at the close.
    #[test]
    fn a_first_bar_strategy_trades_once_a_day_with_the_range_stop() {
        let strategy: Strategy = serde_json::from_value(serde_json::json!({
            "strategy_id": null,
            "strategy_name": "orb",
            "version": "1",
            "instrument": "NAS100_USD",
            "granularity": "M5",
            "components": {
                "or": {"type": "OpeningRange", "params": {"minutes": 5}}
            },
            "entry": {"long": "or.first_bar_up", "short": "or.first_bar_down"},
            "exit": {"long": "or.session_close", "short": "or.session_close"},
            "stop": {"type": "FromComponent", "params": {"component": "or"}},
            "sizing": {"type": "RiskPct", "params": {"pct": 0.01}}
        }))
        .unwrap();
        let mut candles = friday_close();
        let t = open_time();
        candles.push(ohlc(t, 100.0, 101.5, 99.5, 101.0));
        // The rest of the day drifts up without touching 99.5.
        for i in 1..78 {
            let c = 101.0 + i as f64 * 0.01;
            candles.push(ohlc(t + Duration::minutes(5 * i), c, c + 0.05, c - 0.05, c));
        }
        let trades = run_backtest(&candles, &strategy);
        assert_eq!(trades.len(), 1);
        let trade = &trades[0];
        assert_eq!(trade.direction, Direction::Long);
        assert_eq!(trade.entry_time, t);
        assert_eq!(trade.entry_price, 101.0);
        assert_eq!(trade.stop_price, 99.5);
        assert_eq!(trade.exit_reason, ExitReason::TrendReversal);
        assert_eq!(trade.exit_time, t + Duration::minutes(5 * 77));
    }
}
