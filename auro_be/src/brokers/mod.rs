pub mod client;
pub mod massive;
pub mod oanda;
pub mod questrade;
pub mod wealthsimple;

use chrono::{DateTime, Duration, Utc};
use serde::Serialize;

use crate::engine::types::Granularity;

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
}
