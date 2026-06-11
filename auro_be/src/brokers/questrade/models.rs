use serde::{Deserialize, Serialize};

/// Response from POST https://login.questrade.com/oauth2/token
#[derive(Debug, Deserialize)]
pub struct TokenResponse {
    pub access_token: String,
    pub token_type: String,
    pub expires_in: u64,
    pub refresh_token: String,
    pub api_server: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuestradeAccount {
    pub number: String,
    #[serde(rename = "type")]
    pub account_type: String,
    pub status: String,
    #[serde(rename = "isPrimary")]
    pub is_primary: bool,
    #[serde(rename = "isBilling")]
    pub is_billing: bool,
    #[serde(rename = "clientAccountType")]
    pub client_account_type: String,
}

#[derive(Debug, Deserialize)]
pub struct AccountsResponse {
    pub accounts: Vec<QuestradeAccount>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BalanceEntry {
    pub currency: String,
    pub cash: f64,
    pub market_value: f64,
    pub total_equity: f64,
    pub buying_power: f64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountBalancesResponse {
    pub combined_balances: Vec<BalanceEntry>,
}

// ── Market data ─────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SymbolResult {
    pub symbol: String,
    pub symbol_id: i64,
    pub description: String,
    pub listing_exchange: String,
    pub currency: String,
    pub is_tradable: bool,
    pub is_quotable: bool,
}

#[derive(Debug, Deserialize)]
pub struct SymbolSearchResponse {
    pub symbols: Vec<SymbolResult>,
}

/// Raw candle as returned by Questrade — field names match the API exactly.
/// volume is f64 because Questrade returns fractional volume for some instruments.
#[derive(Debug, Deserialize)]
pub struct RawCandle {
    pub start: String,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub volume: f64,
    #[serde(rename = "VWAP")]
    pub vwap: Option<f64>,
}

#[derive(Debug, Deserialize)]
pub struct CandlesResponse {
    pub candles: Vec<RawCandle>,
}

/// Clean candle shape returned from our API endpoint.
#[derive(Debug, Serialize)]
pub struct EquityCandle {
    pub time: String,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub volume: f64,
    pub vwap: Option<f64>,
}

/// Single quote entry from GET /v1/markets/quotes?ids=...
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuoteResult {
    pub symbol: String,
    pub symbol_id: i64,
    pub last_trade_price: Option<f64>,
    pub bid_price: Option<f64>,
    pub ask_price: Option<f64>,
}

#[derive(Debug, Deserialize)]
pub struct QuotesResponse {
    pub quotes: Vec<QuoteResult>,
}
