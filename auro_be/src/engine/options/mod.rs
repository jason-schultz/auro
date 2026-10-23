//! Options math and the contract shape shared by every source. Historical
//! option bars (Massive) come with no greeks or implied volatility, so
//! everything a backtest needs beyond price is computed here from the
//! contract price, the underlying price, time to expiry and a rate. Live
//! chain snapshots (Questrade) carry the exchange's own greeks and are
//! stored as reported.
//!
//! European Black-Scholes-Merton with a continuous dividend yield. US equity
//! options are American, but for the near-the-money, short-dated contracts
//! the strategies care about the early-exercise premium is small next to
//! the bid/ask spread; revisit if deep-ITM puts on high-yield names matter.
//!
//! Modules: `black_scholes` (price, greeks, implied vol, normal functions),
//! `ticker` (OCC symbol parse/format), `vol` (realized-vol estimators, IV
//! rank/percentile, expected move), `income` (premium-selling metrics,
//! assignment probability, strike at a target delta), `scenarios` (expiry
//! outcomes and headline numbers for one single-leg position).

pub mod black_scholes;
pub mod income;
pub mod scenarios;
pub mod ticker;
pub mod vol;

use chrono::{DateTime, Duration, NaiveDate, TimeZone, Utc};
use chrono_tz::America::New_York;

pub use black_scholes::{greeks, implied_vol, price, Greeks, OptionKind};
pub use ticker::OccTicker;

/// One listed contract as the `option_contracts` table stores it, whichever
/// vendor listed it. `ticker` is the OCC form with the `O:` prefix
/// (`O:SPY261219C00650000`), so Massive bars and Questrade quotes for the
/// same contract land on the same row.
#[derive(Debug, Clone, PartialEq)]
pub struct ContractSpec {
    pub ticker: String,
    pub underlying: String,
    pub kind: OptionKind,
    pub expiration: NaiveDate,
    pub strike: f64,
    pub shares_per_contract: i32,
    /// `american`, `european` or `bermudan`, lowercase.
    pub exercise_style: Option<String>,
    pub primary_exchange: Option<String>,
}

/// Strike window `spot × (1 ∓ pct)`.
pub fn strike_band(spot: f64, pct: f64) -> (f64, f64) {
    (spot * (1.0 - pct), spot * (1.0 + pct))
}

/// Inclusive expiry window from `today` out `max_days` calendar days.
pub fn expiry_window(today: NaiveDate, max_days: i64) -> (NaiveDate, NaiveDate) {
    (today, today + Duration::days(max_days))
}

/// Year fraction from `now` to the contract's expiry, taken as 16:00 New
/// York on the expiration date (equity options stop trading at the close).
/// Never negative; an expired contract gives 0.
pub fn years_to_expiry(now: DateTime<Utc>, expiration: NaiveDate) -> f64 {
    let close = expiration.and_hms_opt(16, 0, 0).expect("valid time");
    let Some(expiry) = New_York.from_local_datetime(&close).single() else {
        return 0.0;
    };
    let seconds = (expiry.with_timezone(&Utc) - now).num_seconds().max(0) as f64;
    seconds / (365.0 * 86_400.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn years_to_expiry_counts_to_the_new_york_close() {
        // 2026-10-22 20:00 UTC is 16:00 New York (EDT): a same-day expiry is 0.
        let now = Utc.with_ymd_and_hms(2026, 10, 22, 20, 0, 0).unwrap();
        let today = NaiveDate::from_ymd_opt(2026, 10, 22).unwrap();
        assert_eq!(years_to_expiry(now, today), 0.0);
        // One day later: exactly 1/365.
        let tomorrow = NaiveDate::from_ymd_opt(2026, 10, 23).unwrap();
        assert!((years_to_expiry(now, tomorrow) - 1.0 / 365.0).abs() < 1e-12);
        // Already expired: clamped to zero, never negative.
        let yesterday = NaiveDate::from_ymd_opt(2026, 10, 21).unwrap();
        assert_eq!(years_to_expiry(now, yesterday), 0.0);
    }

    #[test]
    fn strike_band_is_symmetric_around_spot() {
        let (lo, hi) = strike_band(650.0, 0.1);
        assert!((lo - 585.0).abs() < 1e-9 && (hi - 715.0).abs() < 1e-9);
        assert_eq!(
            expiry_window(NaiveDate::from_ymd_opt(2026, 10, 22).unwrap(), 60).1,
            NaiveDate::from_ymd_opt(2026, 12, 21).unwrap()
        );
    }
}
