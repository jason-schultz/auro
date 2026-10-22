use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::engine::types::{Candle, OHLC};

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
    /// Usually an integer, but OANDA serialises it as a float (`49.0`) once a
    /// partial unit has been taken out of a level, which happens on every
    /// tick right after one of our own fills.
    pub liquidity: f64,
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

impl Candlestick {
    /// The single OANDA → `Candle` conversion. Returns None for incomplete
    /// candles (an in-progress bar must never reach a buffer or the DB) and for
    /// unparseable payloads.
    pub fn complete_candle(&self) -> Option<Candle> {
        if !self.complete {
            return None;
        }
        Some(Candle {
            time: DateTime::parse_from_rfc3339(&self.time)
                .ok()?
                .with_timezone(&Utc),
            mid: self.mid.as_ref()?.to_ohlc()?,
            volume: self.volume,
            bid: self.bid.as_ref().and_then(CandlestickData::to_ohlc),
            ask: self.ask.as_ref().and_then(CandlestickData::to_ohlc),
        })
    }
}

impl CandlestickData {
    fn to_ohlc(&self) -> Option<OHLC> {
        Some(OHLC {
            open: self.o.parse().ok()?,
            high: self.h.parse().ok()?,
            low: self.l.parse().ok()?,
            close: self.c.parse().ok()?,
        })
    }
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
    pub trade_units_precision: Option<i32>,
    /// Absent for instruments OANDA doesn't finance (none today, but the
    /// field is optional in the API).
    #[serde(default)]
    pub financing: Option<InstrumentFinancing>,
}

/// OANDA's financing rates for an instrument: annual fractions, negative when
/// the position pays. OANDA sends them as decimal strings.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstrumentFinancing {
    #[serde(deserialize_with = "decimal_string")]
    pub long_rate: f64,
    #[serde(deserialize_with = "decimal_string")]
    pub short_rate: f64,
}

/// OANDA's DecimalNumber: a number encoded as a JSON string.
fn decimal_string<'de, D: serde::Deserializer<'de>>(d: D) -> Result<f64, D::Error> {
    let raw = String::deserialize(d)?;
    raw.parse::<f64>()
        .map_err(|e| serde::de::Error::custom(format!("bad decimal {raw:?}: {e}")))
}

#[cfg(test)]
mod tests {
    use super::{CandlesResponse, Instrument, StreamMessage};

    #[test]
    fn stream_price_accepts_fractional_liquidity() {
        // Observed 2026-10-21 16:00:03Z on NAS100_USD, the tick after our fill.
        let raw = r#"{"type":"PRICE","time":"2026-10-21T16:00:03.836833835Z","instrument":"NAS100_USD",
                      "bids":[{"price":"29873.4","liquidity":50},{"price":"29872.7","liquidity":49.0}],
                      "asks":[{"price":"29874.2","liquidity":50}],"tradeable":true}"#;
        match serde_json::from_str::<StreamMessage>(raw).unwrap() {
            StreamMessage::PRICE(p) => assert_eq!(p.bids[1].liquidity, 49.0),
            other => panic!("expected PRICE, got {other:?}"),
        }
    }

    #[test]
    fn parses_instrument_financing_decimal_strings() {
        let raw = r#"{"name": "EUR_USD", "displayName": "EUR/USD", "type": "CURRENCY",
                      "financing": {"longRate": "-0.0245", "shortRate": "0.0042",
                                    "financingDaysOfWeek": [{"dayOfWeek": "WEDNESDAY", "daysCharged": 3}]}}"#;
        let inst: Instrument = serde_json::from_str(raw).unwrap();
        let f = inst.financing.unwrap();
        assert_eq!((f.long_rate, f.short_rate), (-0.0245, 0.0042));

        let raw = r#"{"name": "EUR_USD", "displayName": "EUR/USD", "type": "CURRENCY"}"#;
        assert!(serde_json::from_str::<Instrument>(raw)
            .unwrap()
            .financing
            .is_none());
    }

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

        let converted = candle.complete_candle().expect("complete candle converts");
        assert_eq!(converted.time.to_rfc3339(), "2026-05-20T10:00:00+00:00");
        assert_eq!(converted.mid.close, 1.1005);
        assert_eq!(converted.bid.unwrap().low, 1.0989);
        assert_eq!(converted.ask.unwrap().high, 1.1011);
        assert_eq!(converted.volume, 1234);
    }

    #[test]
    fn incomplete_candle_never_converts() {
        let candle: super::Candlestick = serde_json::from_value(serde_json::json!({
            "time": "2026-05-20T10:00:00.000000000Z",
            "complete": false,
            "volume": 1,
            "mid": {"o": "1", "h": "1", "l": "1", "c": "1"}
        }))
        .unwrap();
        assert!(candle.complete_candle().is_none());
    }
}
