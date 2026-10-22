use chrono::DateTime;
use serde::{Deserialize, Serialize};

use crate::engine::types::{Candle, OHLC};
use crate::error::{AppError, AppResult};

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

impl TryFrom<&EquityCandle> for Candle {
    type Error = AppError;

    /// The shared `candles` row shape. Equity bars are trade prices, so they
    /// fill `mid` and leave bid/ask empty; per-bar VWAP has no column and is
    /// dropped (session VWAP is recomputable from price × volume).
    fn try_from(bar: &EquityCandle) -> AppResult<Candle> {
        let time = DateTime::parse_from_rfc3339(&bar.time)
            .map_err(|e| {
                AppError::Internal(format!("Bad Questrade candle time '{}': {}", bar.time, e))
            })?
            .to_utc();
        Ok(Candle::from_trade_bar(
            time,
            OHLC {
                open: bar.open,
                high: bar.high,
                low: bar.low,
                close: bar.close,
            },
            bar.volume,
        ))
    }
}

/// Single quote entry from GET /v1/markets/quotes?ids=...
/// Deserializes Questrade's camelCase, serializes snake_case like the rest of
/// our API. Every market field is optional: Questrade nulls them outside
/// trading hours and for halted or illiquid symbols.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all(deserialize = "camelCase"))]
pub struct QuoteResult {
    pub symbol: String,
    pub symbol_id: i64,
    pub last_trade_price: Option<f64>,
    pub last_trade_time: Option<String>,
    pub bid_price: Option<f64>,
    pub bid_size: Option<f64>,
    pub ask_price: Option<f64>,
    pub ask_size: Option<f64>,
    pub open_price: Option<f64>,
    pub high_price: Option<f64>,
    pub low_price: Option<f64>,
    pub volume: Option<f64>,
    /// Seconds of delay on this quote; 0 = real-time.
    pub delay: Option<i64>,
    pub is_halted: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct QuotesResponse {
    pub quotes: Vec<QuoteResult>,
}

/// Minimum price increment that applies at or above `pivot`.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all(deserialize = "camelCase"))]
pub struct MinTick {
    pub pivot: f64,
    pub min_tick: f64,
}

/// Symbol reference data from GET /v1/symbols?ids=...
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all(deserialize = "camelCase"))]
pub struct SymbolDetail {
    pub symbol: String,
    pub symbol_id: i64,
    pub description: String,
    pub listing_exchange: String,
    pub currency: String,
    pub security_type: Option<String>,
    pub is_tradable: bool,
    pub is_quotable: bool,
    pub market_cap: Option<f64>,
    pub outstanding_shares: Option<f64>,
    #[serde(rename(deserialize = "averageVol3Months"))]
    pub average_vol_3_months: Option<f64>,
    #[serde(rename(deserialize = "averageVol20Days"))]
    pub average_vol_20_days: Option<f64>,
    pub prev_day_close_price: Option<f64>,
    #[serde(rename(deserialize = "highPrice52"))]
    pub high_price_52: Option<f64>,
    #[serde(rename(deserialize = "lowPrice52"))]
    pub low_price_52: Option<f64>,
    pub industry_sector: Option<String>,
    pub industry_group: Option<String>,
    pub industry_subgroup: Option<String>,
    #[serde(default)]
    pub min_ticks: Vec<MinTick>,
}

#[derive(Debug, Deserialize)]
pub struct SymbolsResponse {
    pub symbols: Vec<SymbolDetail>,
}
