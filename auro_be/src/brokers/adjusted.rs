//! Daily bars come split-adjusted as of the day they're fetched, from
//! Massive and Questrade alike. After a split, a nightly fetch returns its
//! few days on the new scale while older stored bars stay on the old one,
//! and neither vendor will refetch decades of history (Massive's free plan
//! serves two years). Spot the change where fetched and stored bars
//! overlap, and put everything stored before it on the new scale.

use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use sqlx::PgPool;

use crate::db::repositories::candles as candles_repo;
use crate::engine::types::{CandleRow, Granularity};

/// A refetched daily close this far from the stored one means the vendor
/// has re-adjusted the history (a split), not corrected a bar.
const ADJUSTMENT_TOLERANCE: f64 = 0.01;

/// Overlapping stored days that must all have moved.
const MIN_MOVED: usize = 2;

/// Stored history moved onto the vendor's new scale.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Rescaled {
    /// Stored close ÷ fetched close (a 2:1 split is 2.0).
    pub ratio: f64,
    /// Every stored bar starting before this was rescaled.
    pub before: DateTime<Utc>,
    pub bars: u64,
}

/// Before storing freshly fetched daily `rows`, check them against what is
/// stored; on a re-adjustment, rescale every stored bar of the symbol up
/// to the last old-scale day (the fresh rows then overwrite their own
/// days). None when nothing moved, or for intraday rows.
pub async fn match_stored_scale(
    pool: &PgPool,
    rows: &[CandleRow],
) -> Result<Option<Rescaled>, sqlx::Error> {
    let (Some(first), Some(last)) = (rows.first(), rows.last()) else {
        return Ok(None);
    };
    if first.granularity != Granularity::D {
        return Ok(None);
    }
    let stored = candles_repo::closes_between(
        pool,
        &first.instrument,
        Granularity::D,
        first.candle.time,
        last.candle.time,
    )
    .await?;
    let Some((ratio, last_old)) = adjustment(&stored, rows) else {
        return Ok(None);
    };
    // The whole old-scale day, intraday bars included.
    let before = last_old + Duration::days(1);
    let bars = candles_repo::rescale_before(pool, &first.instrument, before, ratio).await?;
    tracing::warn!(
        "{} daily closes moved ×{:.4} against stored bars (split?); \
         rescaled {} stored bars before {}",
        first.instrument,
        ratio,
        bars,
        before
    );
    Ok(Some(Rescaled {
        ratio,
        before,
        bars,
    }))
}

/// Stored close ÷ fetched close, with the newest stored day still on the
/// old scale, when the stored bars the fetch overlaps moved together: at
/// least `MIN_MOVED` of them, every one up to that day, all by the same
/// ratio (within `ADJUSTMENT_TOLERANCE`). Rescaling rewrites history, so
/// one odd bar, or bars that disagree, is never taken for a split; None.
fn adjustment(
    stored: &[(DateTime<Utc>, f64)],
    fetched: &[CandleRow],
) -> Option<(f64, DateTime<Utc>)> {
    let overlap: Vec<(DateTime<Utc>, f64)> = stored
        .iter()
        .filter_map(|(time, stored_close)| {
            let row = fetched.iter().find(|r| r.candle.time == *time)?;
            let ratio = stored_close / row.candle.mid.close;
            ratio.is_finite().then_some((*time, ratio))
        })
        .collect();
    let moved = |r: f64| (r - 1.0).abs() > ADJUSTMENT_TOLERANCE;
    let last_old = overlap
        .iter()
        .filter(|(_, r)| moved(*r))
        .map(|(t, _)| *t)
        .max()?;
    let old: Vec<f64> = overlap
        .iter()
        .filter(|(t, _)| *t <= last_old)
        .map(|(_, r)| *r)
        .collect();
    let ratio = old[0];
    let together = old.len() >= MIN_MOVED
        && old
            .iter()
            .all(|r| moved(*r) && (r / ratio - 1.0).abs() <= ADJUSTMENT_TOLERANCE);
    together.then_some((ratio, last_old))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::{Candle, OHLC};
    use chrono::TimeZone;

    fn day(d: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, d, 4, 0, 0).unwrap()
    }

    fn fetched(d: u32, close: f64) -> CandleRow {
        CandleRow {
            instrument: "NVDA".into(),
            granularity: Granularity::D,
            candle: Candle::from_trade_bar(
                day(d),
                OHLC {
                    open: close,
                    high: close,
                    low: close,
                    close,
                },
                0.0,
            ),
        }
    }

    #[test]
    fn a_split_shows_as_the_stored_to_fetched_ratio_up_to_the_last_old_day() {
        // 2:1 split effective the 22nd: the fetch halves the 20th and 21st.
        let rows = vec![fetched(20, 100.0), fetched(21, 101.0), fetched(22, 102.0)];
        let stored = vec![(day(20), 200.0), (day(21), 202.0)];
        let (ratio, last_old) = adjustment(&stored, &rows).unwrap();
        assert!((ratio - 2.0).abs() < 1e-9);
        assert_eq!(last_old, day(21));
        // A reverse split shows below one.
        let stored = vec![(day(20), 10.0), (day(21), 10.1)];
        let (ratio, _) = adjustment(&stored, &rows).unwrap();
        assert!((ratio - 0.1).abs() < 1e-9);
    }

    #[test]
    fn one_odd_bar_or_bars_that_disagree_are_not_a_split() {
        let rows = vec![fetched(19, 99.0), fetched(20, 100.0), fetched(21, 101.0)];
        // Only one overlapping day moved: a bad bar, or too little to tell.
        assert_eq!(adjustment(&[(day(21), 202.0)], &rows), None);
        // An odd day in the middle, its neighbours unmoved.
        let stored = vec![(day(19), 99.0), (day(20), 150.0), (day(21), 101.0)];
        assert_eq!(adjustment(&stored, &rows), None);
        // Days moved by different amounts.
        let stored = vec![(day(19), 198.0), (day(20), 300.0), (day(21), 202.0)];
        assert_eq!(adjustment(&stored, &rows), None);
    }

    #[test]
    fn small_corrections_and_new_bars_are_not_a_split() {
        let rows = vec![fetched(20, 100.0), fetched(21, 101.0)];
        // Within 1%: a vendor correction, not an adjustment.
        assert_eq!(adjustment(&[(day(20), 100.5)], &rows), None);
        // No overlap (all new bars) or nothing stored.
        assert_eq!(adjustment(&[(day(19), 50.0)], &rows), None);
        assert_eq!(adjustment(&[], &rows), None);
    }
}
