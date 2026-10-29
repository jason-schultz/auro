//! Weekly stub bars in OANDA's daily index candles.
//!
//! Index daily candles are aligned to the 16:00 New York cash close
//! (`brokers::oanda::client::candle_query`), but index CFDs trade until the
//! 17:00 weekend close, so every week OANDA returns a bar that opens Friday
//! 16:00 and holds just that hour (about a hundredth of a day's volume and an
//! eighth of its range). Counted as a day it skews every bar-count window: a
//! 100-bar average spans about 80 sessions, an ATR shrinks by about a fifth,
//! RSI(2) reacts to one hour, and a 10-bar hold lasts about 8 sessions. And a
//! backtest could decide on its close, an hour no live decision is ever made.
//!
//! So the stub is folded into the bar after it, the one Sunday evening opens
//! (labelled Sunday 16:00): that bar keeps its own time and close and takes
//! the stub's open, the wider of the two ranges and both volumes, so a stop
//! the Friday hour reached is still seen. The stored candles stay as OANDA
//! sent them; everything reading bars for a strategy folds them on the way
//! in (`db::repositories::candles` loaders and the live buffer push).
//! A few early Saturday-labelled bars (2012) are folded the same way.

use chrono::{Datelike, Timelike, Weekday};
use chrono_tz::America::New_York;

use crate::engine::pipeline::{instrument_class, InstrumentClass};
use crate::engine::types::{Candle, Granularity, OHLC};

/// Whether `candle` is a weekly stub: a daily index bar that opens Friday
/// 16:00 New York or later in the weekend.
pub fn is_stub(instrument: &str, granularity: Granularity, candle: &Candle) -> bool {
    if granularity != Granularity::D || instrument_class(instrument) != InstrumentClass::Index {
        return false;
    }
    let ny = candle.time.with_timezone(&New_York);
    match ny.weekday() {
        Weekday::Fri => ny.hour() >= 16,
        Weekday::Sat => true,
        _ => false,
    }
}

/// `next` with `stub`'s hour folded in: `next`'s time and close, `stub`'s
/// open, the wider range, both volumes.
pub fn merge(stub: &Candle, next: &Candle) -> Candle {
    let side = |s: &Option<OHLC>, n: &Option<OHLC>| match (s, n) {
        (Some(s), Some(n)) => Some(merge_ohlc(s, n)),
        (_, n) => n.clone(),
    };
    Candle {
        time: next.time,
        mid: merge_ohlc(&stub.mid, &next.mid),
        volume: stub.volume.saturating_add(next.volume),
        bid: side(&stub.bid, &next.bid),
        ask: side(&stub.ask, &next.ask),
    }
}

fn merge_ohlc(stub: &OHLC, next: &OHLC) -> OHLC {
    OHLC {
        open: stub.open,
        high: stub.high.max(next.high),
        low: stub.low.min(next.low),
        close: next.close,
    }
}

/// `candles` (oldest first) with every stub folded into the bar after it. A
/// stub with no bar after it yet (the weekend's, newest) stays last, as it
/// does in the live buffer, until the next bar arrives to fold it into; no
/// decision is made on it live, since it closes with the market shut.
pub fn fold_stubs(instrument: &str, granularity: Granularity, candles: Vec<Candle>) -> Vec<Candle> {
    let mut folded: Vec<Candle> = Vec::with_capacity(candles.len());
    let mut pending: Option<Candle> = None;
    for candle in candles {
        if is_stub(instrument, granularity, &candle) {
            pending = Some(match pending.take() {
                Some(earlier) => merge(&earlier, &candle),
                None => candle,
            });
            continue;
        }
        folded.push(match pending.take() {
            Some(stub) => merge(&stub, &candle),
            None => candle,
        });
    }
    folded.extend(pending);
    folded
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{DateTime, TimeZone, Utc};

    fn bar(time: DateTime<Utc>, open: f64, high: f64, low: f64, close: f64, volume: i32) -> Candle {
        let ohlc = OHLC {
            open,
            high,
            low,
            close,
        };
        Candle {
            time,
            mid: ohlc.clone(),
            volume,
            bid: Some(ohlc.clone()),
            ask: Some(ohlc),
        }
    }

    // New York is UTC−4 in October: 16:00 New York = 20:00 UTC.
    fn ny_16(day: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, day, 20, 0, 0).unwrap()
    }

    #[test]
    fn the_friday_stub_folds_into_the_bar_sunday_opens() {
        let candles = vec![
            bar(ny_16(22), 100.0, 102.0, 99.0, 101.0, 200_000), // Thu
            bar(ny_16(23), 101.0, 101.5, 98.0, 99.0, 1_000),    // Fri stub
            bar(ny_16(25), 99.5, 103.0, 99.2, 102.0, 180_000),  // Sun
        ];
        assert!(is_stub("SPX500_USD", Granularity::D, &candles[1]));

        let folded = fold_stubs("SPX500_USD", Granularity::D, candles);
        assert_eq!(folded.len(), 2);
        let monday = &folded[1];
        assert_eq!(monday.time, ny_16(25));
        assert_eq!(
            (
                monday.mid.open,
                monday.mid.high,
                monday.mid.low,
                monday.mid.close
            ),
            (101.0, 103.0, 98.0, 102.0)
        );
        assert_eq!(monday.volume, 181_000);
        assert_eq!(monday.bid.as_ref().map(|b| b.low), Some(98.0));
    }

    #[test]
    fn a_stub_with_nothing_after_it_yet_stays_last_to_fold_later() {
        let candles = vec![
            bar(ny_16(22), 100.0, 102.0, 99.0, 101.0, 200_000),
            bar(ny_16(23), 101.0, 101.5, 98.0, 99.0, 1_000),
        ];
        let folded = fold_stubs("NAS100_USD", Granularity::D, candles);
        assert_eq!(folded.len(), 2);
        assert!(is_stub("NAS100_USD", Granularity::D, &folded[1]));
    }

    #[test]
    fn other_instruments_and_timeframes_are_untouched() {
        let friday = bar(ny_16(23), 1.0, 1.0, 1.0, 1.0, 1);
        assert!(!is_stub("EUR_USD", Granularity::D, &friday));
        assert!(!is_stub("SPX500_USD", Granularity::H1, &friday));
        // A Friday bar that opens before 16:00 is a real day.
        let thursday_session = bar(
            ny_16(23) - chrono::Duration::hours(4),
            1.0,
            1.0,
            1.0,
            1.0,
            1,
        );
        assert!(!is_stub("SPX500_USD", Granularity::D, &thursday_session));
    }
}
