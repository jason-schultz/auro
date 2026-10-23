use chrono::{DateTime, NaiveDate, Utc};
use serde::de::DeserializeOwned;
use serde::Deserialize;

use crate::engine::options::{ContractSpec, OptionKind};
use crate::engine::types::{Candle, OHLC};
use crate::error::{AppError, AppResult};

/// One page of any Massive list endpoint. `results` is absent (not empty)
/// when the window has no rows; `next_url` is present when the window
/// exceeded `limit`. `message`/`error` are set on `NOT_AUTHORIZED` / `ERROR`.
#[derive(Debug, Deserialize)]
pub struct Page<T> {
    pub status: String,
    #[serde(default = "Vec::new")]
    pub results: Vec<T>,
    pub next_url: Option<String>,
    pub message: Option<String>,
    pub error: Option<String>,
}

impl<T: DeserializeOwned> Page<T> {
    /// Parse a page body and turn a vendor error status into our error.
    pub fn parse(status: reqwest::StatusCode, body: &str) -> AppResult<Self> {
        let page: Self = serde_json::from_str(body).map_err(|e| {
            AppError::Internal(format!(
                "Massive response (HTTP {status}) not understood: {e}: {}",
                body.chars().take(200).collect::<String>()
            ))
        })?;
        match page.status.as_str() {
            "OK" | "DELAYED" => Ok(page),
            other => Err(AppError::Internal(format!(
                "Massive {other}: {}",
                page.error
                    .clone()
                    .or(page.message.clone())
                    .unwrap_or_default()
            ))),
        }
    }
}

/// `GET /v2/aggs/ticker/{ticker}/range/...` response.
pub type AggregatesResponse = Page<AggBar>;

/// `GET /v3/reference/options/contracts` response.
pub type ContractsResponse = Page<OptionContract>;

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
    /// Trade count in the bar; absent on some older rows.
    #[serde(default)]
    pub n: Option<i64>,
}

/// One listed option contract (`/v3/reference/options/contracts`). The
/// `ticker` is the OCC-style `O:SPY251219C00650000`.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct OptionContract {
    pub ticker: String,
    pub underlying_ticker: String,
    /// `call`, `put`, or rarely `other`.
    pub contract_type: String,
    /// `american`, `european`, or `bermudan`.
    pub exercise_style: Option<String>,
    pub expiration_date: NaiveDate,
    pub strike_price: f64,
    /// The vendor serialises this as a number; 100 for standard contracts.
    #[serde(default = "default_shares")]
    pub shares_per_contract: f64,
    pub primary_exchange: Option<String>,
}

fn default_shares() -> f64 {
    100.0
}

impl TryFrom<&OptionContract> for ContractSpec {
    type Error = AppError;

    /// The vendor's `contract_type` "other" (rare adjusted contracts) has no
    /// place in `option_contracts`; callers skip those with a warning.
    fn try_from(c: &OptionContract) -> AppResult<Self> {
        let kind = OptionKind::parse(&c.contract_type).ok_or_else(|| {
            AppError::Internal(format!(
                "Massive contract {} has contract_type {:?}",
                c.ticker, c.contract_type
            ))
        })?;
        Ok(ContractSpec {
            ticker: c.ticker.clone(),
            underlying: c.underlying_ticker.clone(),
            kind,
            expiration: c.expiration_date,
            strike: c.strike_price,
            shares_per_contract: c
                .shares_per_contract
                .round()
                .clamp(1.0, f64::from(i32::MAX)) as i32,
            exercise_style: c.exercise_style.clone(),
            primary_exchange: c.primary_exchange.clone(),
        })
    }
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
            n: None,
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
        let resp = AggregatesResponse::parse(reqwest::StatusCode::OK, json).unwrap();
        assert_eq!(resp.status, "OK");
        assert!(resp.results.is_empty());
        assert!(resp.next_url.is_none());
    }

    #[test]
    fn plan_limit_message_becomes_an_error() {
        let json = r#"{"status":"NOT_AUTHORIZED","request_id":"x","message":"Your plan doesn't include this data timeframe."}"#;
        let err = AggregatesResponse::parse(reqwest::StatusCode::OK, json).unwrap_err();
        assert!(err.to_string().contains("NOT_AUTHORIZED"));
        assert!(err.to_string().contains("plan"));
    }

    #[test]
    fn contracts_page_parses_vendor_record() {
        let json = r#"{"status":"OK","request_id":"x","next_url":"https://api.massive.com/v3/reference/options/contracts?cursor=abc",
          "results":[{"cfi":"OCASPS","contract_type":"call","exercise_style":"american",
            "expiration_date":"2026-12-19","primary_exchange":"BATO","shares_per_contract":100,
            "strike_price":650,"ticker":"O:SPY261219C00650000","underlying_ticker":"SPY"}]}"#;
        let page = ContractsResponse::parse(reqwest::StatusCode::OK, json).unwrap();
        assert!(page.next_url.is_some());
        let c = &page.results[0];
        assert_eq!(c.ticker, "O:SPY261219C00650000");
        assert_eq!(c.contract_type, "call");
        assert_eq!(
            c.expiration_date,
            NaiveDate::from_ymd_opt(2026, 12, 19).unwrap()
        );
        assert_eq!(c.strike_price, 650.0);
        assert_eq!(c.shares_per_contract, 100.0);
    }
}
