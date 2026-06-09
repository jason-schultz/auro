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
    pub maximum_order_units: Option<String>,
    pub minimum_trailing_stop_distance: Option<String>,
    pub maximum_trailing_stop_distance: Option<String>,
    pub trade_units_precision: Option<i32>,
}

#[cfg(test)]
mod tests {
    use super::CandlesResponse;

    #[test]
    fn parses_bam_candle_payload() {
        let raw = r#"
                {
                    "instrument": "EUR_USD",
                    "granularity": "H1",
                    "candles": [
                        {
                            "time": "2026-05-20T10:00:00.000000000Z",
                            "complete": true,
                            "volume": 1234,
                            "mid": {"o": "1.1000", "h": "1.1010", "l": "1.0990", "c": "1.1005"},
                            "bid": {"o": "1.0999", "h": "1.1009", "l": "1.0989", "c": "1.1004"},
                            "ask": {"o": "1.1001", "h": "1.1011", "l": "1.0991", "c": "1.1006"}
                        }
                    ]
                }
                "#;

        let parsed: CandlesResponse =
            serde_json::from_str(raw).expect("BAM payload should deserialize");

        assert_eq!(parsed.instrument, "EUR_USD");
        assert_eq!(parsed.granularity, "H1");
        assert_eq!(parsed.candles.len(), 1);

        let candle = &parsed.candles[0];
        assert!(candle.bid.is_some());
        assert!(candle.ask.is_some());
        assert!(candle.mid.is_some());
        assert_eq!(candle.bid.as_ref().unwrap().c, "1.1004");
        assert_eq!(candle.ask.as_ref().unwrap().c, "1.1006");
    }
}

// pub enum TradeOrderUpdate {
//     Set {price: String},
//     SetTrailing {distance: String},
//     Cancel,
// }
