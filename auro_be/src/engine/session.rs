//! The NYSE regular session in New York time (09:30–16:00, 13:00 on early-
//! close days), for the components that think in sessions: the noise band,
//! VWAP, the opening range and pivot points.
//!
//! Candles carry their open time in UTC; a bar belongs to the regular session
//! when it opens at or after 09:30 and before the close. Components only see
//! candles, so the bar length is inferred (`indicators::bar_minutes`).

use chrono::{Datelike, Duration, NaiveDate, Timelike, Weekday};
use chrono_tz::America::New_York;

use crate::engine::indicators;
use crate::engine::types::Candle;

/// Minutes after midnight New York time.
pub(crate) const SESSION_OPEN_MIN: i64 = 9 * 60 + 30;
pub(crate) const SESSION_CLOSE_MIN: i64 = 16 * 60;
pub(crate) const EARLY_CLOSE_MIN: i64 = 13 * 60;

/// Where the newest bar sits in the New York session.
pub(crate) struct BarClock {
    pub(crate) bar_minutes: i64,
    /// New York minute-of-day at which the newest bar closes.
    pub(crate) close_min: i64,
    /// That day's session close, in the same minutes.
    pub(crate) session_close_min: i64,
}

impl BarClock {
    pub(crate) fn of(candles: &[Candle]) -> Option<Self> {
        let bar_minutes = indicators::bar_minutes(candles)?;
        let close =
            (candles.last()?.time + Duration::minutes(bar_minutes)).with_timezone(&New_York);
        Some(Self {
            bar_minutes,
            close_min: i64::from(close.hour()) * 60 + i64::from(close.minute()),
            session_close_min: session_close_min(close.date_naive()),
        })
    }

    /// The bar closes at or after the session close, or before the open: a
    /// position shouldn't carry past it.
    pub(crate) fn is_session_close(&self) -> bool {
        self.close_min >= self.session_close_min || self.close_min <= SESSION_OPEN_MIN
    }
}

/// NYSE closes at 13:00 on the day after Thanksgiving, and on July 3 and
/// December 24 when they fall Monday–Thursday (a Friday July 3 / December 24
/// is itself the observed holiday).
pub(crate) fn session_close_min(date: NaiveDate) -> i64 {
    let weekday = date.weekday();
    let mon_to_thu = weekday.number_from_monday() <= 4;
    let early = match (date.month(), date.day()) {
        (7, 3) | (12, 24) => mon_to_thu,
        // Fourth Thursday of November is day 22–28, so the Friday is 23–29.
        (11, day) => weekday == Weekday::Fri && (23..=29).contains(&day),
        _ => false,
    };
    if early {
        EARLY_CLOSE_MIN
    } else {
        SESSION_CLOSE_MIN
    }
}

/// A candle's New York date and the minute of day it opens.
pub(crate) fn ny_open(candle: &Candle) -> (NaiveDate, i64) {
    let ny = candle.time.with_timezone(&New_York);
    (
        ny.date_naive(),
        i64::from(ny.hour()) * 60 + i64::from(ny.minute()),
    )
}

/// Whether a bar opening at `start_min` is in the regular session.
pub(crate) fn in_regular_session(start_min: i64) -> bool {
    (SESSION_OPEN_MIN..SESSION_CLOSE_MIN).contains(&start_min)
}

/// Today's regular-session bars so far: the bars on the newest bar's New
/// York date that open inside the session, oldest first. Empty when the
/// newest bar is outside the session.
pub(crate) fn today(candles: &[Candle]) -> &[Candle] {
    let Some(last) = candles.last() else {
        return candles;
    };
    let (date, start) = ny_open(last);
    if !in_regular_session(start) {
        return &candles[candles.len()..];
    }
    let from = candles
        .iter()
        .rposition(|c| {
            let (d, m) = ny_open(c);
            d != date || !in_regular_session(m)
        })
        .map_or(0, |i| i + 1);
    &candles[from..]
}

/// The high, low and close of the latest regular session before the newest
/// bar's date. For daily bars, the previous bar's.
pub(crate) fn previous_session(candles: &[Candle]) -> Option<(f64, f64, f64)> {
    let last = candles.last()?;
    if indicators::bar_minutes(candles)? >= 24 * 60 {
        let prev = &candles[candles.len().checked_sub(2)?];
        return Some((prev.mid.high, prev.mid.low, prev.mid.close));
    }
    let (today, _) = ny_open(last);
    let mut bars = candles.iter().rev().filter(|c| {
        let (d, m) = ny_open(c);
        d < today && in_regular_session(m)
    });
    let newest = bars.next()?;
    let (date, _) = ny_open(newest);
    let session: Vec<&Candle> = std::iter::once(newest)
        .chain(bars.take_while(|c| ny_open(c).0 == date))
        .collect();
    let high = session.iter().map(|c| c.mid.high).fold(f64::MIN, f64::max);
    let low = session.iter().map(|c| c.mid.low).fold(f64::MAX, f64::min);
    Some((high, low, newest.mid.close))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::{DateTime, TimeZone, Utc};

    fn bar(time: DateTime<Utc>, high: f64, low: f64, close: f64) -> Candle {
        Candle {
            time,
            mid: OHLC {
                open: close,
                high,
                low,
                close,
            },
            volume: 10,
            bid: None,
            ask: None,
        }
    }

    #[test]
    fn early_close_days_follow_nyse_rules() {
        let d = |y, m, day| NaiveDate::from_ymd_opt(y, m, day).unwrap();
        assert_eq!(session_close_min(d(2025, 11, 28)), EARLY_CLOSE_MIN); // Black Friday
        assert_eq!(session_close_min(d(2024, 12, 24)), EARLY_CLOSE_MIN); // Tuesday
        assert_eq!(session_close_min(d(2025, 7, 3)), EARLY_CLOSE_MIN); // Thursday
        assert_eq!(session_close_min(d(2026, 7, 3)), SESSION_CLOSE_MIN); // Friday: holiday
        assert_eq!(session_close_min(d(2021, 12, 24)), SESSION_CLOSE_MIN); // Friday: holiday
        assert_eq!(session_close_min(d(2025, 11, 21)), SESSION_CLOSE_MIN); // a week early
    }

    /// 2026-01-05 is a Monday in EST: 09:30 New York = 14:30 UTC.
    fn monday(h: u32, m: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 1, 5, h, m, 0).unwrap()
    }

    #[test]
    fn today_is_the_newest_dates_regular_session_bars() {
        let candles = vec![
            bar(monday(14, 0), 1.0, 1.0, 1.0),  // 09:00, pre-market
            bar(monday(14, 30), 2.0, 2.0, 2.0), // 09:30
            bar(monday(14, 35), 3.0, 3.0, 3.0), // 09:35
        ];
        let today = today(&candles);
        assert_eq!(today.len(), 2);
        assert_eq!(today[0].mid.close, 2.0);
    }

    #[test]
    fn previous_session_is_yesterdays_regular_hours() {
        let candles = vec![
            bar(monday(14, 30), 105.0, 99.0, 101.0),
            bar(monday(20, 55), 103.0, 100.0, 102.0), // 15:55, last bar
            bar(monday(21, 30), 120.0, 80.0, 100.0),  // 16:30, after hours
            bar(monday(14, 30) + Duration::days(1), 1.0, 1.0, 1.0),
        ];
        assert_eq!(previous_session(&candles), Some((105.0, 99.0, 102.0)));
    }
}
