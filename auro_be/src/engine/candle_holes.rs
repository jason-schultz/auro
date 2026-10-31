//! Holes in a stored candle history: stretches where a failed backfill page
//! or a feed outage left no bars. Every backtest window is built by index,
//! so a hole makes two bars weeks apart look adjacent: indicators see one
//! jump, an open trade is stopped on whatever bar comes next, and financing
//! is charged for the real days. The pipeline refuses a history with one
//! (`pipeline::load_subject`), so it gets backfilled rather than tested.
//!
//! A gap is measured in weekdays with no bar at all between two bars (UTC
//! dates). Markets do close for a few weekdays at a time: four after 9/11,
//! five or six for China's holidays on CN50. More than
//! `MAX_MISSING_WEEKDAYS` is a hole.

use chrono::{Datelike, NaiveDate, Weekday};

use crate::engine::types::Candle;

/// The most weekdays in a row a market is taken to close for. A longer gap
/// is missing data.
pub const MAX_MISSING_WEEKDAYS: usize = 6;

/// A stretch with no bars: the last bar before it, the first after, and the
/// weekdays between them with none.
#[derive(Debug, Clone, PartialEq)]
pub struct Hole {
    pub after: NaiveDate,
    pub before: NaiveDate,
    pub missing_weekdays: usize,
}

/// Every hole in `candles` (oldest first), oldest first.
pub fn holes(candles: &[Candle]) -> Vec<Hole> {
    candles
        .windows(2)
        .filter_map(|pair| {
            let after = pair[0].time.date_naive();
            let before = pair[1].time.date_naive();
            let missing = weekdays_between(after, before);
            (missing > MAX_MISSING_WEEKDAYS).then_some(Hole {
                after,
                before,
                missing_weekdays: missing,
            })
        })
        .collect()
}

/// Weekdays strictly between `a` and `b`.
fn weekdays_between(a: NaiveDate, b: NaiveDate) -> usize {
    a.iter_days()
        .skip(1)
        .take_while(|d| *d < b)
        .filter(|d| !matches!(d.weekday(), Weekday::Sat | Weekday::Sun))
        .count()
}

/// `market`'s holes in words, for a stage that refuses to run: the first
/// few, and how many more. None without any.
pub fn refusal(market: &str, candles: &[Candle]) -> Option<String> {
    let found = holes(candles);
    if found.is_empty() {
        return None;
    }
    let shown: Vec<String> = found
        .iter()
        .take(3)
        .map(|h| {
            format!(
                "{} and {} ({} weekdays)",
                h.after.format("%b %-d, %Y"),
                h.before.format("%b %-d, %Y"),
                h.missing_weekdays
            )
        })
        .collect();
    let more = match found.len() {
        n if n > 3 => format!(" and {} more", n - 3),
        _ => String::new(),
    };
    Some(format!(
        "{market}'s history has bars missing: none between {}{more}. A test across the gap would read weeks apart as one bar; backfill it first",
        shown.join(", ")
    ))
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};

    use super::*;
    use crate::engine::types::OHLC;

    fn bar(y: i32, m: u32, d: u32) -> Candle {
        let price = OHLC {
            open: 1.0,
            high: 1.0,
            low: 1.0,
            close: 1.0,
        };
        Candle::from_trade_bar(Utc.with_ymd_and_hms(y, m, d, 20, 0, 0).unwrap(), price, 0.0)
    }

    #[test]
    fn weekends_and_short_closures_are_not_holes() {
        // Fri → Mon, and 9/11's four weekdays (Mon 10th → Mon 17th).
        let bars = [bar(2001, 9, 7), bar(2001, 9, 10), bar(2001, 9, 17)];
        assert!(holes(&bars).is_empty());
        assert_eq!(refusal("SPY", &bars), None);
    }

    #[test]
    fn more_than_six_missing_weekdays_is_a_hole() {
        // SPY's stored daily bars skip Oct 29 – Nov 11, 2021: 10 weekdays.
        let bars = [bar(2021, 10, 28), bar(2021, 11, 12), bar(2021, 11, 15)];
        assert_eq!(
            holes(&bars),
            vec![Hole {
                after: NaiveDate::from_ymd_opt(2021, 10, 28).unwrap(),
                before: NaiveDate::from_ymd_opt(2021, 11, 12).unwrap(),
                missing_weekdays: 10,
            }]
        );
        let words = refusal("SPY", &bars).unwrap();
        assert!(
            words.contains("none between Oct 28, 2021 and Nov 12, 2021 (10 weekdays)"),
            "{words}"
        );
    }
}
