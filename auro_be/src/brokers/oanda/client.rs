use reqwest::{Client, RequestBuilder, Response};
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use tokio::time::Instant;

use super::models::*;
use crate::brokers::client::BrokerClient;
use crate::brokers::{BrokerAccount, BrokerKind, BrokerStatus};
use crate::engine::pipeline::{instrument_class, InstrumentClass};
use crate::error::{AppError, AppResult};

#[derive(Debug, Clone)]
pub struct OandaClient {
    http_client: Client,
    /// The earliest moment the next REST request may leave. Shared by every
    /// clone, so the candle feed, trade management and the API handlers
    /// draw from one budget.
    next_slot: Arc<Mutex<Instant>>,
    base_url: String,
    stream_url: String,
    api_key: String,
    account_id: String,
}

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

/// Spacing between REST requests: 50 a second, well under OANDA's
/// per-second limit. The streaming connection is not paced.
const REQUEST_SPACING: Duration = Duration::from_millis(20);

impl OandaClient {
    pub fn new(base_url: &str, stream_url: &str, api_key: &str, account_id: &str) -> Self {
        let http_client = Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .build()
            .expect("failed to build OANDA HTTP client");

        Self {
            http_client,
            next_slot: Arc::new(Mutex::new(Instant::now())),
            base_url: base_url.trim_end_matches('/').to_string(),
            stream_url: stream_url.trim_end_matches('/').to_string(),
            api_key: api_key.to_string(),
            account_id: account_id.to_string(),
        }
    }

    pub fn account_id(&self) -> &str {
        &self.account_id
    }

    /// Wait for this request's slot in the shared pacing budget, then send.
    /// Slots are handed out in arrival order, so a burst of feed polls
    /// queues instead of tripping OANDA's rate limit.
    async fn send(&self, request: RequestBuilder) -> reqwest::Result<Response> {
        let slot = {
            let mut next = self.next_slot.lock().await;
            let slot = (*next).max(Instant::now());
            *next = slot + REQUEST_SPACING;
            slot
        };
        tokio::time::sleep_until(slot).await;
        request.send().await
    }

    // --- Account ---

    pub async fn get_account(&self) -> AppResult<Account> {
        let url = format!("{}/v3/accounts/{}", self.base_url, self.account_id);

        let resp = self
            .send(
                self.http_client
                    .get(&url)
                    .bearer_auth(&self.api_key)
                    .timeout(REQUEST_TIMEOUT),
            )
            .await
            .map_err(|e| AppError::Oanda(e.to_string()))?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(AppError::Oanda(format!("HTTP {}: {}", status, body)));
        }

        let body = resp
            .text()
            .await
            .map_err(|e| AppError::Oanda(format!("Failed to read account response body: {}", e)))?;

        let account_resp: AccountResponse = serde_json::from_str(&body).map_err(|e| {
            AppError::Oanda(format!(
                "Failed to parse account response: {} | Body: {}",
                e,
                body.chars().take(500).collect::<String>()
            ))
        })?;

        Ok(account_resp.account)
    }

    // --- Instruments ---

    pub async fn get_instruments(&self) -> AppResult<Vec<Instrument>> {
        let url = format!(
            "{}/v3/accounts/{}/instruments",
            self.base_url, self.account_id
        );

        let resp = self
            .send(
                self.http_client
                    .get(&url)
                    .bearer_auth(&self.api_key)
                    .timeout(REQUEST_TIMEOUT),
            )
            .await
            .map_err(|e| AppError::Oanda(e.to_string()))?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(AppError::Oanda(format!("HTTP {}: {}", status, body)));
        }

        let instruments_resp: InstrumentsResponse = resp
            .json()
            .await
            .map_err(|e| AppError::Oanda(format!("Failed to parse instruments: {}", e)))?;

        Ok(instruments_resp.instruments)
    }

    // --- Pricing ---

    pub async fn get_pricing(&self, instruments: &[&str]) -> AppResult<Vec<Price>> {
        let url = format!("{}/v3/accounts/{}/pricing", self.base_url, self.account_id);

        let instruments_param = instruments.join(",");

        let resp = self
            .send(
                self.http_client
                    .get(&url)
                    .bearer_auth(&self.api_key)
                    .query(&[("instruments", &instruments_param)])
                    .timeout(REQUEST_TIMEOUT),
            )
            .await
            .map_err(|e| AppError::Oanda(e.to_string()))?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(AppError::Oanda(format!("HTTP {}: {}", status, body)));
        }

        let pricing_resp: PricingResponse = resp
            .json()
            .await
            .map_err(|e| AppError::Oanda(format!("Failed to parse pricing: {}", e)))?;

        Ok(pricing_resp.prices)
    }

    // --- Candles ---

    pub async fn get_candles(
        &self,
        instrument: &str,
        granularity: &str,
        count: Option<i32>,
        from: Option<&str>,
        to: Option<&str>,
    ) -> AppResult<CandlesResponse> {
        let url = format!("{}/v3/instruments/{}/candles", self.base_url, instrument);

        let query = candle_query(instrument, granularity, count, from, to);

        let resp = self
            .send(
                self.http_client
                    .get(&url)
                    .bearer_auth(&self.api_key)
                    .query(&query)
                    .timeout(REQUEST_TIMEOUT),
            )
            .await
            .map_err(|e| AppError::Oanda(e.to_string()))?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(AppError::Oanda(format!("HTTP {}: {}", status, body)));
        }

        let candles_resp: CandlesResponse = resp
            .json()
            .await
            .map_err(|e| AppError::Oanda(format!("Failed to parse candles: {}", e)))?;

        Ok(candles_resp)
    }

    // --- Streaming ---

    /// Returns a byte stream from the OANDA pricing stream endpoint.
    /// Each line is a JSON object (either a PRICE or HEARTBEAT message).
    /// The caller is responsible for reading and parsing lines.
    pub async fn pricing_stream(&self, instruments: &[&str]) -> AppResult<reqwest::Response> {
        let url = format!(
            "{}/v3/accounts/{}/pricing/stream",
            self.stream_url, self.account_id
        );

        let instruments_param = instruments.join(",");

        let resp = self
            .http_client
            .get(&url)
            .bearer_auth(&self.api_key)
            .query(&[("instruments", &instruments_param)])
            .send()
            .await
            .map_err(|e| AppError::Oanda(e.to_string()))?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(AppError::Oanda(format!("Stream HTTP {}: {}", status, body)));
        }

        Ok(resp)
    }

    // --- Orders ---
    /// Market order with a server-side stop loss. Every live entry carries
    /// the stop its strategy config computed; exits are strategy-driven.
    /// A fill-or-kill market order with its stop attached. `client_id`
    /// labels the trade it opens (`tradeClientExtensions.id`), so a trade
    /// whose response was lost (a timeout after the fill) can be found in
    /// the open trades and tracked instead of left unmanaged.
    pub async fn create_market_order(
        &self,
        instrument: &str,
        units: &str,
        stop_loss_price: &str,
        client_id: &str,
    ) -> AppResult<serde_json::Value> {
        let url = format!("{}/v3/accounts/{}/orders", self.base_url, self.account_id);

        let body = json!({
            "order": {
                "type": "MARKET",
                "instrument": instrument,
                "units": units,
                "timeInForce": "FOK",
                "positionFill": "DEFAULT",
                "stopLossOnFill": {"price": stop_loss_price, "timeInForce": "GTC"},
                "tradeClientExtensions": {"id": client_id, "tag": "auro"},
            }
        });

        let resp = self
            .send(
                self.http_client
                    .post(&url)
                    .bearer_auth(&self.api_key)
                    .json(&body)
                    .timeout(REQUEST_TIMEOUT),
            )
            .await
            .map_err(|e| AppError::Oanda(e.to_string()))?;

        let status = resp.status();
        let resp_body: Value = resp
            .json()
            .await
            .map_err(|e| AppError::Oanda(format!("Failed to parse order response: {}", e)))?;

        if !status.is_success() {
            let error_msg = resp_body["errorMessage"]
                .as_str()
                .unwrap_or("Unknown error");
            return Err(AppError::Oanda(format!(
                "Order failed ({}): {}",
                status, error_msg
            )));
        }

        Ok(resp_body)
    }

    pub async fn get_open_trades(&self) -> AppResult<serde_json::Value> {
        let url = format!(
            "{}/v3/accounts/{}/openTrades",
            self.base_url, self.account_id
        );

        let resp = self
            .send(
                self.http_client
                    .get(&url)
                    .bearer_auth(&self.api_key)
                    .timeout(REQUEST_TIMEOUT),
            )
            .await
            .map_err(|e| AppError::Oanda(e.to_string()))?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(AppError::Oanda(format!("HTTP {}: {}", status, body)));
        }

        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| AppError::Oanda(format!("Failed to parse trades: {}", e)))?;

        Ok(body)
    }

    pub async fn close_trade(
        &self,
        trade_id: &str,
        units: Option<&str>,
    ) -> AppResult<serde_json::Value> {
        let url = format!(
            "{}/v3/accounts/{}/trades/{}/close",
            self.base_url, self.account_id, trade_id
        );

        let body = match units {
            Some(u) => serde_json::json!({ "units": u }),
            None => serde_json::json!({}), // close all units
        };

        let resp = self
            .send(
                self.http_client
                    .put(&url)
                    .bearer_auth(&self.api_key)
                    .json(&body)
                    .timeout(REQUEST_TIMEOUT),
            )
            .await
            .map_err(|e| AppError::Oanda(e.to_string()))?;

        let status = resp.status();
        let resp_body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| AppError::Oanda(format!("Failed to parse close response: {}", e)))?;

        if !status.is_success() {
            let error_msg = resp_body["errorMessage"]
                .as_str()
                .unwrap_or("Unknown error");
            return Err(AppError::Oanda(format!(
                "Close trade failed ({}): {}",
                status, error_msg
            )));
        }

        Ok(resp_body)
    }

    /// Fetch details for a single trade (open or closed) by its OANDA trade ID.
    /// Used by the reconciler to get exit price and reason when OANDA closes a trade via SL/TP.
    pub async fn get_trade(&self, trade_id: &str) -> AppResult<serde_json::Value> {
        let url = format!(
            "{}/v3/accounts/{}/trades/{}",
            self.base_url, self.account_id, trade_id
        );

        let resp = self
            .send(
                self.http_client
                    .get(&url)
                    .bearer_auth(&self.api_key)
                    .timeout(REQUEST_TIMEOUT),
            )
            .await
            .map_err(|e| AppError::Oanda(e.to_string()))?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(AppError::Oanda(format!("HTTP {}: {}", status, body)));
        }

        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| AppError::Oanda(format!("Failed to parse trade: {}", e)))?;

        Ok(body)
    }

    /// Fetch a single OANDA transaction by transaction id.
    pub async fn get_transaction(&self, transaction_id: &str) -> AppResult<serde_json::Value> {
        let url = format!(
            "{}/v3/accounts/{}/transactions/{}",
            self.base_url, self.account_id, transaction_id
        );

        let resp = self
            .send(
                self.http_client
                    .get(&url)
                    .bearer_auth(&self.api_key)
                    .timeout(REQUEST_TIMEOUT),
            )
            .await
            .map_err(|e| AppError::Oanda(e.to_string()))?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(AppError::Oanda(format!("HTTP {}: {}", status, body)));
        }

        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| AppError::Oanda(format!("Failed to parse transaction: {}", e)))?;

        Ok(body)
    }

    /// Fetch transactions after a given transaction id.
    pub async fn list_transactions_since(&self, since_id: &str) -> AppResult<serde_json::Value> {
        let url = format!(
            "{}/v3/accounts/{}/transactions/sinceid",
            self.base_url, self.account_id
        );

        let resp = self
            .send(
                self.http_client
                    .get(&url)
                    .bearer_auth(&self.api_key)
                    .query(&[("id", since_id), ("type", "ORDER_FILL")])
                    .timeout(REQUEST_TIMEOUT),
            )
            .await
            .map_err(|e| AppError::Oanda(e.to_string()))?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(AppError::Oanda(format!("HTTP {}: {}", status, body)));
        }

        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| AppError::Oanda(format!("Failed to parse transactions: {}", e)))?;

        Ok(body)
    }
}

impl OandaClient {
    /// Whether this is OANDA's practice environment (paper money): its API
    /// host is `api-fxpractice.oanda.com`; live is `api-fxtrade.oanda.com`.
    pub fn is_practice(&self) -> bool {
        self.base_url.contains("fxpractice")
    }

    fn environment(&self) -> &'static str {
        if self.is_practice() {
            "Practice"
        } else {
            "Live"
        }
    }
}

impl BrokerClient for OandaClient {
    async fn broker_status(&mut self) -> BrokerStatus {
        match self.get_account().await {
            Err(e) => BrokerStatus {
                broker: BrokerKind::Oanda,
                display_name: "OANDA",
                connected: false,
                error: Some(e.to_string()),
                accounts: vec![],
            },
            Ok(account) => {
                let cash: f64 = account.balance.parse().unwrap_or(0.0);
                let unrealized: f64 = account.unrealized_pl.parse().unwrap_or(0.0);
                let buying_power: Option<f64> = account.margin_available.parse().ok();
                BrokerStatus {
                    broker: BrokerKind::Oanda,
                    display_name: "OANDA",
                    connected: true,
                    error: None,
                    accounts: vec![BrokerAccount {
                        id: account.id.clone(),
                        name: format!("{} ({})", self.environment(), account.id),
                        account_type: self.environment().into(),
                        currency: account.currency,
                        cash: Some(cash),
                        market_value: None,
                        total_equity: Some(cash + unrealized),
                        buying_power,
                        paper: self.is_practice(),
                    }],
                }
            }
        }
    }
}

/// Query for OANDA's candles endpoint. Daily bars for index CFDs are aligned
/// to the 16:00 New York cash close instead of OANDA's default 17:00 FX
/// rollover: the index strategies were researched on 16:00 bars, and a
/// decision taken at 17:00 fills into the 17:00–18:00 halt where spreads are
/// widest. Forex, metals and bonds have no cash close, so they keep 17:00, as
/// does H4 on every instrument.
fn candle_query(
    instrument: &str,
    granularity: &str,
    count: Option<i32>,
    from: Option<&str>,
    to: Option<&str>,
) -> Vec<(&'static str, String)> {
    let mut query = vec![
        ("granularity", granularity.to_string()),
        ("price", "BAM".to_string()),
    ];
    if granularity == "D" && instrument_class(instrument) == InstrumentClass::Index {
        query.push(("dailyAlignment", "16".to_string()));
        query.push(("alignmentTimezone", "America/New_York".to_string()));
    }
    if let Some(c) = count {
        query.push(("count", c.to_string()));
    }
    if let Some(f) = from {
        query.push(("from", f.to_string()));
    }
    if let Some(t) = to {
        query.push(("to", t.to_string()));
    }
    query
}

#[cfg(test)]
mod candle_query_tests {
    use super::candle_query;

    #[test]
    fn index_daily_bars_align_to_the_new_york_cash_close() {
        for inst in ["SPX500_USD", "EU50_EUR", "US2000_USD"] {
            let q = candle_query(inst, "D", Some(10), None, None);
            assert!(q.contains(&("dailyAlignment", "16".to_string())), "{inst}");
            assert!(q.contains(&("alignmentTimezone", "America/New_York".to_string())));
            assert!(q.contains(&("count", "10".to_string())));
        }
    }

    #[test]
    fn other_daily_bars_and_all_intraday_bars_keep_oanda_defaults() {
        for (inst, g) in [
            ("EUR_USD", "D"),
            ("XAU_USD", "D"),
            ("USB10Y_USD", "D"),
            ("SPX500_USD", "H4"),
            ("SPX500_USD", "M5"),
        ] {
            let q = candle_query(inst, g, None, Some("2026-01-01T00:00:00Z"), None);
            assert!(!q.iter().any(|(k, _)| *k == "dailyAlignment"), "{inst} {g}");
            assert!(q.contains(&("from", "2026-01-01T00:00:00Z".to_string())));
        }
    }
}

#[cfg(test)]
mod environment_tests {
    use super::OandaClient;

    #[test]
    fn the_practice_host_is_paper_money() {
        let practice = OandaClient::new("https://api-fxpractice.oanda.com", "s", "k", "a");
        let live = OandaClient::new("https://api-fxtrade.oanda.com/", "s", "k", "a");
        assert!(practice.is_practice());
        assert!(!live.is_practice());
        assert_eq!(live.environment(), "Live");
    }
}
