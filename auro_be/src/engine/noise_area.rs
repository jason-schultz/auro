//! Noise-area intraday momentum — Zarattini, Aziz & Barbon (2024), "Beat the
//! Market: An Effective Intraday Momentum Strategy for S&P500 ETF (SPY)",
//! SFI Research Paper 24-97.
//!
//! The noise area at each time of day is the average absolute move from the
//! session open, at that same time, over the prior `lookback_sessions` regular
//! sessions (scaled by `band_mult`). Bands are gap-adjusted:
//! upper = max(open, prev close) × (1 + σ), lower = min(open, prev close) × (1 − σ).
//! Price outside the bands at a decision time signals momentum; the trailing
//! exit is the band or the session VWAP, whichever is tighter.
//!
//! Session is NYSE regular hours (09:30–16:00 America/New_York, 13:00 on
//! early-close days), the session the paper is cited on. Decisions happen
//! only at bar closes on the half-hour (10:00, 10:30, … up to the last one
//! before the close). `session_close` fires on any bar closing at or after the
//! close or before the open, so a position never carries overnight — CFDs keep
//! trading past the cash close, but a missed close bar still exits on the
//! next one.
//!
//! Deviations from the paper: VWAP weights by OANDA tick volume (CFDs have no
//! traded volume), and sizing is Auro's RiskPct against the opposite-band stop
//! instead of the paper's volatility target.

use std::collections::HashMap;

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

use crate::engine::catalog::{port, Block, Series, Setting};
use crate::engine::session::{
    in_regular_session, ny_open, BarClock, SESSION_CLOSE_MIN, SESSION_OPEN_MIN,
};
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

/// Minutes after midnight New York time.
const FIRST_DECISION_MIN: i64 = 10 * 60;
const DECISION_INTERVAL_MIN: i64 = 30;
const M5_BARS_PER_DAY: usize = 24 * 60 / 5;

fn default_lookback_sessions() -> usize {
    14
}

fn default_band_mult() -> f64 {
    1.0
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct NoiseAreaParams {
    #[serde(default = "default_lookback_sessions")]
    pub lookback_sessions: usize,
    #[serde(default = "default_band_mult")]
    pub band_mult: f64,
}

/// Band state at a decision bar.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Bands {
    upper: f64,
    lower: f64,
    vwap: f64,
    price: f64,
}

/// Decisions happen at bar closes on the half-hour from 10:00 until the
/// last one before the close.
fn is_decision(clock: &BarClock) -> bool {
    DECISION_INTERVAL_MIN % clock.bar_minutes == 0
        && (FIRST_DECISION_MIN..clock.session_close_min).contains(&clock.close_min)
        && (clock.close_min - FIRST_DECISION_MIN) % DECISION_INTERVAL_MIN == 0
}

/// Regular-session bars of one New York date, indexed by slot from the open.
struct Session {
    date: NaiveDate,
    bars: Vec<Option<Candle>>,
}

impl Session {
    fn is_complete(&self) -> bool {
        self.bars.iter().all(Option::is_some)
    }

    fn open(&self) -> Option<f64> {
        self.bars.first()?.as_ref().map(|c| c.mid.open)
    }

    fn close_at(&self, slot: usize) -> Option<f64> {
        self.bars.get(slot)?.as_ref().map(|c| c.mid.close)
    }
}

impl NoiseAreaParams {
    /// Bands at the newest bar. Requires today's session open plus
    /// `lookback_sessions` complete prior sessions in the window; the newest
    /// complete prior session also supplies the previous close.
    fn bands(&self, candles: &[Candle], clock: &BarClock) -> Option<Bands> {
        let slots = ((SESSION_CLOSE_MIN - SESSION_OPEN_MIN) / clock.bar_minutes) as usize;
        let now_slot = ((clock.close_min - SESSION_OPEN_MIN) / clock.bar_minutes - 1) as usize;
        let sessions = self.recent_sessions(candles, clock.bar_minutes, slots)?;
        let (today, prior) = sessions.split_first()?;

        let complete: Vec<&Session> = prior
            .iter()
            .filter(|s| s.is_complete())
            .take(self.lookback_sessions)
            .collect();
        if complete.len() < self.lookback_sessions || self.lookback_sessions == 0 {
            return None;
        }

        let sigma = complete
            .iter()
            .map(|s| Some((s.close_at(now_slot)? / s.open()? - 1.0).abs()))
            .sum::<Option<f64>>()?
            / complete.len() as f64
            * self.band_mult;

        let open = today.open()?;
        let prev_close = complete[0].close_at(slots - 1)?;

        let (pv, v) = today.bars[..=now_slot]
            .iter()
            .flatten()
            .fold((0.0, 0.0), |(pv, v), c| {
                let vol = f64::from(c.volume.max(1));
                let typical = (c.mid.high + c.mid.low + c.mid.close) / 3.0;
                (pv + typical * vol, v + vol)
            });

        Some(Bands {
            upper: open.max(prev_close) * (1.0 + sigma),
            lower: open.min(prev_close) * (1.0 - sigma),
            vwap: pv / v,
            price: candles.last()?.mid.close,
        })
    }

    /// Group regular-session bars by New York date, newest session first,
    /// walking back only as far as `lookback_sessions` complete prior
    /// sessions. The newest session must be today's (the newest bar's date).
    fn recent_sessions(
        &self,
        candles: &[Candle],
        bar_minutes: i64,
        slots: usize,
    ) -> Option<Vec<Session>> {
        let mut sessions: Vec<Session> = Vec::new();
        for candle in candles.iter().rev() {
            let (date, start_min) = ny_open(candle);
            if !in_regular_session(start_min) {
                continue;
            }
            if sessions.last().is_none_or(|s| s.date != date) {
                let complete_prior = sessions.iter().skip(1).filter(|s| s.is_complete()).count();
                if complete_prior >= self.lookback_sessions {
                    break;
                }
                sessions.push(Session {
                    date,
                    bars: vec![None; slots],
                });
            }
            let slot = ((start_min - SESSION_OPEN_MIN) / bar_minutes) as usize;
            if let Some(session) = sessions.last_mut() {
                session.bars[slot] = Some(candle.clone());
            }
        }

        let (today, _) = ny_open(candles.last()?);
        (sessions.first()?.date == today).then_some(sessions)
    }

    fn bands_at_decision(&self, candles: &[Candle]) -> Option<Bands> {
        let clock = BarClock::of(candles)?;
        if !is_decision(&clock) {
            return None;
        }
        self.bands(candles, &clock)
    }
}

/// This block in the catalog (`engine::catalog`).
pub(crate) fn catalog() -> Block {
    Block {
        kind: "NoiseArea",
        key: "na",
        name: "Noise band",
        watches: "How far the price usually moves from the US open by this time of day. Moving past that usual range suggests a real move, not noise. Intraday bars only.",
        settings: vec![
            Setting::int(
                "lookback_sessions",
                "Sessions to average",
                14,
                "More sessions make a steadier band.",
            ),
            Setting::float(
                "band_mult",
                "Band width ×",
                1.0,
                "Wider means only bigger breakouts count.",
            ),
        ],
        ports: vec![
            port("long", "the price breaks above the noise band (the usual move from the open, over the last {lookback_sessions} sessions)"),
            port("short", "the price breaks below the noise band (the usual move from the open, over the last {lookback_sessions} sessions)"),
            port("exit_long", "the price falls back below the band or the day's average price (VWAP)"),
            port("exit_short", "the price rises back above the band or the day's average price (VWAP)"),
            port("session_close", "the US session ends (16:00 New York)"),
        ],
        series: vec![
            Series::price("upper", "Band top"),
            Series::price("lower", "Band bottom"),
            Series::price("vwap", "Day's average price (VWAP)"),
        ],
        stop: Some("the other side of the noise band"),
    }
}

impl Signaler for NoiseAreaParams {
    /// Whole days of M5 bars, not regular-session bars: CFD candles also
    /// cover the overnight session, so a window sized to 6½ hours a day
    /// holds only about a third of the sessions the band needs. The real
    /// requirement — enough complete prior sessions — is still checked at
    /// each decision bar.
    fn warmup(&self) -> usize {
        (self.lookback_sessions + 1) * M5_BARS_PER_DAY
    }

    /// Non-decision bars always compute (all signal ports false) so the
    /// session-close exit fires even when history is short, e.g. right after
    /// a restart. Decision bars need full band history or return None.
    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        let clock = BarClock::of(candles)?;
        let mut ports = HashMap::from([
            ("long".to_string(), false),
            ("short".to_string(), false),
            ("exit_long".to_string(), false),
            ("exit_short".to_string(), false),
            ("session_close".to_string(), clock.is_session_close()),
        ]);
        if !is_decision(&clock) {
            return Some(ports);
        }

        let b = self.bands(candles, &clock)?;
        // Strict entries, inclusive-of-band exits: price must clear the band
        // to enter, and anything back inside the tighter trail exits.
        ports.insert("long".to_string(), b.price > b.upper);
        ports.insert("short".to_string(), b.price < b.lower);
        ports.insert("exit_long".to_string(), b.price < b.upper.max(b.vwap));
        ports.insert("exit_short".to_string(), b.price > b.lower.min(b.vwap));
        Some(ports)
    }

    /// The band and the day's average price at decision bars, where the
    /// strategy looks at them.
    fn series(&self, candles: &[Candle]) -> HashMap<String, f64> {
        self.bands_at_decision(candles)
            .map(|b| {
                HashMap::from([
                    ("upper".to_string(), b.upper),
                    ("lower".to_string(), b.lower),
                    ("vwap".to_string(), b.vwap),
                ])
            })
            .unwrap_or_default()
    }

    fn entry_reason(&self, candles: &[Candle], _direction: Direction) -> EntryReason {
        let b = self.bands_at_decision(candles).unwrap_or(Bands {
            upper: 0.0,
            lower: 0.0,
            vwap: 0.0,
            price: 0.0,
        });
        EntryReason::NoiseAreaBreakout {
            upper_band: b.upper,
            lower_band: b.lower,
            vwap: b.vwap,
        }
    }

    /// Protective stop at the opposite band: a long is wrong once price
    /// crosses the whole noise area. The paper has no hard stop (exits only at
    /// decision times); this is the server-side backstop for outages.
    fn stop_price(&self, candles: &[Candle], direction: Direction) -> Option<f64> {
        let b = self.bands_at_decision(candles)?;
        Some(match direction {
            Direction::Long => b.lower,
            Direction::Short => b.upper,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::{DateTime, Datelike, Duration, TimeZone, Utc};

    /// 2026-01-05 is a Monday in EST (UTC−5): 09:30 New York = 14:30 UTC.
    fn session_start(day: i64) -> DateTime<Utc> {
        let mut date = Utc.with_ymd_and_hms(2026, 1, 5, 14, 30, 0).unwrap();
        let mut remaining = day;
        while remaining > 0 {
            date += Duration::days(1);
            if date.weekday().number_from_monday() <= 5 {
                remaining -= 1;
            }
        }
        date
    }

    fn bar(time: DateTime<Utc>, open: f64, close: f64) -> Candle {
        Candle {
            time,
            mid: OHLC {
                open,
                high: open.max(close),
                low: open.min(close),
                close,
            },
            volume: 10,
            bid: None,
            ask: None,
        }
    }

    /// `n` complete prior sessions where every bar closes 0.1% above a
    /// 100.0 open (σ = 0.001 at every slot, previous close = 100.1), then
    /// today's first `today_bars` M5 bars from the given closes.
    fn history(n: i64, today_closes: &[f64]) -> Vec<Candle> {
        let mut candles = Vec::new();
        for day in 0..n {
            let start = session_start(day);
            for slot in 0..78 {
                candles.push(bar(start + Duration::minutes(5 * slot), 100.0, 100.1));
            }
        }
        let start = session_start(n);
        for (slot, close) in today_closes.iter().enumerate() {
            candles.push(bar(
                start + Duration::minutes(5 * slot as i64),
                100.0,
                *close,
            ));
        }
        candles
    }

    fn params() -> NoiseAreaParams {
        NoiseAreaParams {
            lookback_sessions: 14,
            band_mult: 1.0,
        }
    }

    #[test]
    fn breakout_above_upper_band_at_decision_signals_long() {
        // Six bars: 09:30..09:55, newest closes at 10:00 — first decision.
        let candles = history(14, &[100.5; 6]);
        let ports = params().compute(&candles).expect("decision bar computes");

        // upper = max(100.0, 100.1) × 1.001 ≈ 100.2001
        assert!(ports["long"]);
        assert!(!ports["short"]);
        assert!(!ports["exit_long"]);
        assert!(!ports["session_close"]);
    }

    #[test]
    fn stop_is_the_opposite_band() {
        let candles = history(14, &[100.5; 6]);
        let stop = params()
            .stop_price(&candles, Direction::Long)
            .expect("stop at decision bar");
        // lower = min(100.0, 100.1) × 0.999
        assert!((stop - 99.9).abs() < 1e-9);
    }

    #[test]
    fn non_decision_bar_never_signals() {
        // Seven bars: newest closes at 10:05.
        let candles = history(14, &[100.5; 7]);
        let ports = params()
            .compute(&candles)
            .expect("non-decision bars compute");
        assert!(!ports["long"] && !ports["exit_long"] && !ports["session_close"]);
    }

    #[test]
    fn exit_long_when_price_falls_back_under_vwap() {
        // Price ran to 101 then closes the 10:00 bar at 100.3: still above the
        // upper band (≈100.2) but below the session VWAP — the tighter trail.
        let mut closes = vec![101.0; 5];
        closes.push(100.3);
        let ports = params().compute(&history(14, &closes)).expect("computes");
        assert!(ports["long"]);
        assert!(ports["exit_long"]);
    }

    #[test]
    fn last_bar_of_session_fires_session_close() {
        let candles = history(14, &[100.0; 78]);
        let ports = params().compute(&candles).expect("computes");
        assert!(ports["session_close"]);
    }

    #[test]
    fn early_close_day_flattens_at_one_pm() {
        // 2025-11-28 (Black Friday, EST): the bar starting 12:55 closes at 13:00.
        let start = Utc.with_ymd_and_hms(2025, 11, 28, 17, 50, 0).unwrap();
        let candles = vec![
            bar(start, 100.0, 100.0),
            bar(start + Duration::minutes(5), 100.0, 100.0),
        ];
        let ports = params()
            .compute(&candles)
            .expect("non-decision bars compute");
        assert!(ports["session_close"]);
    }

    #[test]
    fn warmup_window_holds_enough_sessions_of_round_the_clock_bars() {
        // CFD candles run around the clock: 288 bars a weekday, then today
        // from midnight UTC to the 10:00 New York decision bar. The history
        // runs longer than the warmup, as the live buffer and backtests do.
        let mut candles = Vec::new();
        for day in 0..=20 {
            let midnight = session_start(day) - Duration::minutes(14 * 60 + 30);
            let open = session_start(day);
            let bars = if day == 20 { 180 } else { 288 };
            for slot in 0..bars {
                let time = midnight + Duration::minutes(5 * slot);
                let close = if day == 20 && time >= open {
                    100.5
                } else {
                    100.1
                };
                candles.push(bar(time, 100.0, close));
            }
        }

        let p = params();
        let window = &candles[candles.len() - p.warmup()..];
        let ports = p.compute(window).expect("warmup window holds 14 sessions");
        assert!(ports["long"]);
    }

    #[test]
    fn decision_without_enough_complete_sessions_is_none() {
        let candles = history(13, &[100.5; 6]);
        assert!(params().compute(&candles).is_none());
    }

    #[test]
    fn incomplete_prior_session_is_skipped_not_counted() {
        // Drop one bar from the most recent prior session: it no longer counts,
        // so 14 sessions of history leave only 13 complete.
        let mut candles = history(14, &[100.5; 6]);
        candles.remove(13 * 78 + 40);
        assert!(params().compute(&candles).is_none());
    }
}
