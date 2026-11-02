pub mod adjusted;
pub mod client;
pub mod connections;
pub mod massive;
pub mod oanda;
pub mod questrade;
pub mod wealthsimple;

use chrono::{DateTime, Duration, TimeZone, Utc};
use chrono_tz::America::New_York;
use serde::Serialize;

use crate::engine::types::Granularity;

/// Midnight New York on the day a US-listed daily bar trades: how daily
/// stock and ETF bars are stamped in `candles`, whichever vendor sent them
/// (Massive already does; Questrade sometimes stamps a bar 01:00).
pub fn stock_day_open(time: DateTime<Utc>) -> DateTime<Utc> {
    let day = time.with_timezone(&New_York).date_naive();
    New_York
        .from_local_datetime(&day.and_hms_opt(0, 0, 0).expect("midnight exists"))
        .earliest()
        .expect("New York midnight exists")
        .with_timezone(&Utc)
}

/// When a stock bar stops changing. Intraday bars are final one bar after
/// they open. Massive and Questrade stamp daily bars at midnight New York and
/// keep updating them through extended hours, which end 20:00 New York, 20
/// hours later.
pub fn stock_bar_final_at(open: DateTime<Utc>, granularity: Granularity) -> DateTime<Utc> {
    match granularity {
        Granularity::D => open + Duration::hours(20),
        other => open + Duration::minutes(other.minutes()),
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BrokerKind {
    Oanda,
    Questrade,
    Wealthsimple,
}

#[derive(Debug, Serialize)]
pub struct BrokerStatus {
    pub broker: BrokerKind,
    pub display_name: &'static str,
    pub connected: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub accounts: Vec<BrokerAccount>,
}

#[derive(Debug, Serialize)]
pub struct BrokerAccount {
    pub id: String,
    pub name: String,
    pub account_type: String,
    pub currency: String,
    pub cash: Option<f64>,
    pub market_value: Option<f64>,
    pub total_equity: Option<f64>,
    pub buying_power: Option<f64>,
    /// Practice money, not real: OANDA's practice environment. Opus keeps
    /// it out of the total and net worth.
    pub paper: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_daily_stock_bar_is_stamped_midnight_new_york() {
        let at = |s: &str| DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc);
        // Questrade's odd 01:00 bar, summer time: the same day's midnight.
        assert_eq!(
            stock_day_open(at("2026-10-26T01:00:00-04:00")),
            at("2026-10-26T00:00:00-04:00")
        );
        // Winter: midnight is 05:00 UTC.
        assert_eq!(
            stock_day_open(at("2012-01-03T00:00:00-05:00")),
            at("2012-01-03T05:00:00Z")
        );
    }
}
