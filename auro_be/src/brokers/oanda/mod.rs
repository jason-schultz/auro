use chrono::{DateTime, Datelike, Timelike, Utc, Weekday};

pub mod backfill;
pub mod client;
pub mod models;
pub mod stream;

/// The OANDA instrument universe: streamed for quotes and kept candle-current
/// at every granularity.
pub const INSTRUMENTS: &[&str] = &[
    "EUR_USD",
    "GBP_USD",
    "USD_CAD",
    "USD_JPY",
    "AUD_USD",
    "XAU_USD",
    "XCU_USD",
    "EUR_JPY",
    "EUR_GBP",
    "EUR_CHF",
    "EUR_CAD",
    "EUR_AUD",
    "GBP_JPY",
    "GBP_AUD",
    "GBP_CAD",
    "AUD_JPY",
    "AUD_NZD",
    "AUD_CAD",
    "NZD_USD",
    "NZD_JPY",
    "NZD_CAD",
    "CAD_JPY",
    "CAD_CHF",
    "CHF_JPY",
    "WTICO_USD",
    "BCO_USD",
    "NATGAS_USD",
    "CORN_USD",
    "SOYBN_USD",
    "WHEAT_USD",
    "SUGAR_USD",
    "XAG_USD",
    "XPT_USD",
    "XPD_USD",
    "SPX500_USD",
    "NAS100_USD",
    "US30_USD",
    "UK100_GBP",
    "DE30_EUR",
    "JP225_USD",
    "AU200_AUD",
    "EU50_EUR",
    "US2000_USD",
    "FR40_EUR",
    "NL25_EUR",
    "CH20_CHF",
    "HK33_HKD",
    "CN50_USD",
    "USB02Y_USD",
    "USB10Y_USD",
    "USB30Y_USD",
    "DE10YB_EUR",
    "UK10YB_GBP",
];

pub fn is_forex_market_open() -> bool {
    is_forex_market_open_at(Utc::now())
}

/// Whether OANDA's weekly session is open at `now`: Sunday 17:00 to Friday
/// 17:00 New York time, daylight saving included.
pub fn is_forex_market_open_at(now: DateTime<Utc>) -> bool {
    let eastern = now.with_timezone(&chrono_tz::US::Eastern);
    let weekday = eastern.weekday();
    let hour = eastern.hour();

    match weekday {
        Weekday::Sat => false,
        Weekday::Sun => hour >= 17, // Opens 5pm ET Sunday
        Weekday::Fri => hour < 17,  // Closes 5pm ET Friday
        _ => true,                  // Open
    }
}
