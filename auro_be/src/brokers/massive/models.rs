use chrono::{DateTime, Utc};
use serde::Deserialize;

use crate::engine::types::{Candle, OHLC};
use crate::error::{AppError, AppResult};

/// `GET /v2/aggs/ticker/{ticker}/range/...` response. `results` is absent
/// (not empty) when the window has no bars; `next_url` is present when the
/// window exceeded `limit`.
#[derive(Debug, Deserialize)]
pub struct AggregatesResponse {
    pub status: String,
    #[serde(default)]
    pub results: Vec<AggBar>,
    pub next_url: Option<String>,
    /// Set on `NOT_AUTHORIZED` / `ERROR` statuses.
    pub message: Option<String>,
    pub error: Option<String>,
}

/// One aggregate bar. Field names are the vendor's single letters.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct AggBar {
    /// Bar start, Unix milliseconds. Daily bars start at midnight New York.
    pub t: i64,
    pub o: f64,
    pub h: f64,
    pub l: f64,
    pub c: f64,
    /// Volume; the vendor serialises large values as floats (`2.58e7`).
    pub v: f64,
}

impl TryFrom<&AggBar> for Candle {
    type Error = AppError;

    /// The shared `candles` row shape: trade prices into `mid`, no bid/ask.
    fn try_from(bar: &AggBar) -> AppResult<Candle> {
        let time = DateTime::<Utc>::from_timestamp_millis(bar.t)
            .ok_or_else(|| AppError::Internal(format!("Bad Massive bar time {}", bar.t)))?;
        Ok(Candle::from_trade_bar(
            time,
            OHLC {
                open: bar.o,
                high: bar.h,
                low: bar.l,
                close: bar.c,
            },
            bar.v,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bar_converts_milliseconds_and_rounds_volume() {
        let bar = AggBar {
            t: 1_791_864_000_000,
            o: 777.34,
            h: 778.75,
            l: 775.95,
            c: 778.01,
            v: 2.5847950815323e7,
        };
        let candle = Candle::try_from(&bar).unwrap();
        assert_eq!(candle.time.to_rfc3339(), "2026-10-13T04:00:00+00:00");
        assert_eq!(candle.mid.close, 778.01);
        assert_eq!(candle.volume, 25_847_951);
        assert!(candle.bid.is_none() && candle.ask.is_none());
    }

    #[test]
    fn response_without_results_deserialises_to_empty() {
        let json = r#"{"ticker":"SPY","queryCount":2,"resultsCount":0,"adjusted":true,"status":"OK","request_id":"x"}"#;
        let resp: AggregatesResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.status, "OK");
        assert!(resp.results.is_empty());
        assert!(resp.next_url.is_none());
    }

    #[test]
    fn plan_limit_message_is_kept() {
        let json = r#"{"status":"NOT_AUTHORIZED","request_id":"x","message":"Your plan doesn't include this data timeframe."}"#;
        let resp: AggregatesResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.status, "NOT_AUTHORIZED");
        assert!(resp.message.unwrap().contains("plan"));
    }
}
