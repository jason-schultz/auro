use serde::{Deserialize, Serialize};

// --- Account ---

#[derive(Debug, Deserialize)]
pub struct AccountResponse {
    pub account: Account,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub id: String,
    pub currency: String,
    pub balance: String,
    #[serde(rename = "unrealizedPL")]
    pub unrealized_pl: String,
    pub pl: String,
    pub open_trade_count: i32,
    pub open_position_count: i32,
    pub margin_used: String,
    pub margin_available: String,
}

// --- Pricing ---

#[derive(Debug, Deserialize)]
pub struct PricingResponse {
    pub prices: Vec<Price>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Price {
    pub instrument: String,
    pub time: String,
    pub asks: Vec<PriceBucket>,
    pub bids: Vec<PriceBucket>,
    pub status: Option<String>,
    pub tradeable: Option<bool>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct PriceBucket {
    pub price: String,
    pub liquidity: i64,
}

// --- Streaming ---

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
pub enum StreamMessage {
    PRICE(StreamPrice),
    HEARTBEAT(StreamHeartbeat),
}

#[derive(Debug, Clone, Deserialize)]
pub struct StreamPrice {
    pub instrument: String,
    pub time: String,
    pub asks: Vec<PriceBucket>,
    pub bids: Vec<PriceBucket>,
    pub tradeable: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StreamHeartbeat {
    pub time: String,
}

// --- Candles ---

#[derive(Debug, Deserialize)]
pub struct CandlesResponse {
    pub instrument: String,
    pub granularity: String,
    pub candles: Vec<Candlestick>,
}

#[derive(Debug, Deserialize)]
pub struct Candlestick {
    pub time: String,
    pub complete: bool,
    pub volume: i32,
    pub mid: Option<CandlestickData>,
    pub bid: Option<CandlestickData>,
    pub ask: Option<CandlestickData>,
}

#[derive(Debug, Deserialize)]
pub struct CandlestickData {
    pub o: String,
    pub h: String,
    pub l: String,
    pub c: String,
}

// --- Instruments ---

#[derive(Debug, Deserialize)]
pub struct InstrumentsResponse {
    pub instruments: Vec<Instrument>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Instrument {
    pub name: String,
    pub display_name: String,
    #[serde(rename = "type")]
    pub instrument_type: String,
    pub pip_location: Option<i32>,
    pub display_precision: Option<i32>,
    pub minimum_trade_size: Option<String>,
}

// pub enum TradeOrderUpdate {
//     Set {price: String},
//     SetTrailing {distance: String},
//     Cancel,
// }
