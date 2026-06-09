pub mod client;
pub mod oanda;
pub mod questrade;
pub mod wealthsimple;

use serde::Serialize;

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
