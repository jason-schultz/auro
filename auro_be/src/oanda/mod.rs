use chrono::{Datelike, Timelike, Utc, Weekday};

pub mod aggregator;
pub mod backfill;
pub mod client;
pub mod models;
pub mod stream;

pub fn is_forex_market_open() -> bool {
    let now = Utc::now();
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
