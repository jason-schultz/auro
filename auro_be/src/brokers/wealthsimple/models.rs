use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize)]
pub struct WealthsimplePosition {
    pub id: i32,
    pub account_id: i32,
    pub symbol: String,
    pub shares: f64,
    pub avg_cost: Option<f64>,
    pub current_price: Option<f64>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct WealthsimpleAccount {
    pub id: i32,
    pub account_type: String,
    pub account_number: Option<String>,
    pub currency: String,
    pub cash: Option<f64>,
    pub market_value: Option<f64>,
    pub total_equity: Option<f64>,
    pub updated_at: DateTime<Utc>,
    pub positions: Vec<WealthsimplePosition>,
}

/// Body for PUT /api/brokers/wealthsimple — replaces the full account + position list.
#[derive(Debug, Deserialize)]
pub struct UpsertWealthsimpleAccounts {
    pub accounts: Vec<UpsertAccount>,
}

#[derive(Debug, Deserialize)]
pub struct UpsertAccount {
    pub account_type: String,
    pub account_number: Option<String>,
    pub currency: String,
    pub cash: Option<f64>,
    pub market_value: Option<f64>,
    pub total_equity: Option<f64>,
    pub positions: Vec<UpsertPosition>,
}

#[derive(Debug, Deserialize)]
pub struct UpsertPosition {
    pub symbol: String,
    pub shares: f64,
    pub avg_cost: Option<f64>,
    pub current_price: Option<f64>,
}
