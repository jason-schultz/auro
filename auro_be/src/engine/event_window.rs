//! Scheduled-event window: `in_window` is true while the next bar lies inside
//! [event + start_offset, event + end_offset) for any listed event. Used for
//! the announcement-day premium (Savor & Wilson 2013) and the pre-FOMC drift
//! (Lucca & Moench 2015). Event times come from Opus, which owns the macro
//! calendar and pushes updated lists into the strategy's parameters.
//!
//! Decisions are made at bar close: a position opened at the close of bar t is
//! held through bar t+1, so the window test is on the *next* bar's span.

use std::collections::HashMap;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use crate::engine::indicators;
use crate::engine::strategy::Signaler;
use crate::engine::types::{Candle, Direction, EntryReason};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct EventWindowParams {
    /// Release times (UTC). Order doesn't matter.
    pub events: Vec<DateTime<Utc>>,
    /// Window start relative to each event, in minutes (negative = before).
    pub start_offset_minutes: i64,
    /// Window end relative to each event, in minutes (0 = exit before release).
    pub end_offset_minutes: i64,
    /// Which Opus calendar keeps `events` current ("fomc", "cpi", "nfp").
    /// Carried for Opus only; the engine never reads it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub calendar: Option<String>,
}

impl EventWindowParams {
    /// The event whose window contains the next bar, if any.
    fn active_event(&self, candles: &[Candle]) -> Option<DateTime<Utc>> {
        let bar = Duration::minutes(indicators::bar_minutes(candles)?);
        let next_start = candles.last()?.time + bar;
        let next_end = next_start + bar;
        self.events.iter().copied().find(|e| {
            next_start >= *e + Duration::minutes(self.start_offset_minutes)
                && next_end <= *e + Duration::minutes(self.end_offset_minutes)
        })
    }
}

impl Signaler for EventWindowParams {
    fn warmup(&self) -> usize {
        2
    }

    fn compute(&self, candles: &[Candle]) -> Option<HashMap<String, bool>> {
        indicators::bar_minutes(candles)?;
        let in_window = self.active_event(candles).is_some();
        Some(HashMap::from([
            ("in_window".to_string(), in_window),
            ("out_of_window".to_string(), !in_window),
        ]))
    }

    fn entry_reason(&self, candles: &[Candle], _direction: Direction) -> EntryReason {
        EntryReason::EventWindow {
            event_time: self
                .active_event(candles)
                .unwrap_or(DateTime::<Utc>::MIN_UTC),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::TimeZone;

    fn hourly(start: DateTime<Utc>, n: i64) -> Vec<Candle> {
        (0..n)
            .map(|i| Candle {
                time: start + Duration::hours(i),
                mid: OHLC {
                    open: 1.0,
                    high: 1.0,
                    low: 1.0,
                    close: 1.0,
                },
                volume: 1,
                bid: None,
                ask: None,
            })
            .collect()
    }

    /// FOMC release 2024-09-18 18:00 UTC; pre-FOMC window = previous day 18:00 → release.
    fn pre_fomc() -> EventWindowParams {
        EventWindowParams {
            events: vec![Utc.with_ymd_and_hms(2024, 9, 18, 18, 0, 0).unwrap()],
            start_offset_minutes: -24 * 60,
            end_offset_minutes: 0,
            calendar: None,
        }
    }

    #[test]
    fn enters_at_close_before_window_start() {
        // Newest bar 2024-09-17 16:00–17:00 closes at 17:00; next bar 17:00–18:00 is still before the window.
        let c = hourly(Utc.with_ymd_and_hms(2024, 9, 17, 14, 0, 0).unwrap(), 3);
        assert!(!pre_fomc().compute(&c).unwrap()["in_window"]);
        // One bar later the next bar starts at 18:00 = window start.
        let c = hourly(Utc.with_ymd_and_hms(2024, 9, 17, 14, 0, 0).unwrap(), 4);
        assert!(pre_fomc().compute(&c).unwrap()["in_window"]);
    }

    #[test]
    fn exits_before_the_release_bar() {
        // Newest bar 16:00–17:00 on release day: next bar 17:00–18:00 ends exactly at the release → still in.
        let c = hourly(Utc.with_ymd_and_hms(2024, 9, 18, 14, 0, 0).unwrap(), 3);
        assert!(pre_fomc().compute(&c).unwrap()["in_window"]);
        // Next bar 18:00–19:00 contains the release → out.
        let c = hourly(Utc.with_ymd_and_hms(2024, 9, 18, 14, 0, 0).unwrap(), 4);
        let ports = pre_fomc().compute(&c).unwrap();
        assert!(!ports["in_window"] && ports["out_of_window"]);
    }

    #[test]
    fn no_events_never_in_window() {
        let p = EventWindowParams {
            events: vec![],
            start_offset_minutes: -60,
            end_offset_minutes: 0,
            calendar: None,
        };
        let c = hourly(Utc.with_ymd_and_hms(2024, 9, 18, 0, 0, 0).unwrap(), 5);
        assert!(!p.compute(&c).unwrap()["in_window"]);
    }
}
