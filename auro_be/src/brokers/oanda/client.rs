use reqwest::Client;
use serde_json::{json, Value};

use super::models::*;
use crate::brokers::client::BrokerClient;
use crate::brokers::{BrokerAccount, BrokerKind, BrokerStatus};
use crate::error::{AppError, AppResult};

#[derive(Debug, Clone)]
pub struct OandaClient {
    http_client: Client,
    base_url: String,
    stream_url: String,
    api_key: String,
    account_id: String,
}

impl OandaClient {
    pub fn new(base_url: &str, stream_url: &str, api_key: &str, account_id: &str) -> Self {
        Self {
            http_client: Client::new(),
            base_url: base_url.trim_end_matches('/').to_string(),
            stream_url: stream_url.trim_end_matches('/').to_string(),
            api_key: api_key.to_string(),
            account_id: account_id.to_string(),
        }
    }

    pub fn account_id(&self) -> &str {
        &self.account_id
    }

    // --- Account ---

    pub async fn get_account(&self) -> AppResult<Account> {
        let url = format!("{}/v3/accounts/{}", self.base_url, self.account_id);

        let resp = self
            .http_client
            .get(&url)
            .bearer_auth(&self.api_key)
            .send()
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
                &body[..body.len().min(500)]
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
            .http_client
            .get(&url)
            .bearer_auth(&self.api_key)
            .send()
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

        let mut query: Vec<(&str, String)> = vec![
            ("granularity", granularity.to_string()),
            ("price", "BAM".to_string()),
        ];

        if let Some(c) = count {
            query.push(("count", c.to_string()));
        }
        if let Some(f) = from {
            query.push(("from", f.to_string()));
        }
        if let Some(t) = to {
            query.push(("to", t.to_string()));
        }

        let resp = self
            .http_client
            .get(&url)
            .bearer_auth(&self.api_key)
            .query(&query)
            .send()
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
    pub async fn create_market_order(
        &self,
        instrument: &str,
        units: &str,
        stop_loss_price: Option<&str>,
        take_profit_price: Option<&str>,
        trailing_stop_distance: Option<&str>,
    ) -> AppResult<serde_json::Value> {
        let url = format!("{}/v3/accounts/{}/orders", self.base_url, self.account_id);

        let mut order = json!({
            "type": "MARKET",
            "instrument": instrument,
            "units": units,
            "timeInForce": "FOK",
            "positionFill": "DEFAULT",
        });

        if let Some(dist) = trailing_stop_distance {
            order["trailingStopLossOnFill"] = json!({"distance": dist, "timeInForce": "GTC"});
        } else if let Some(sl) = stop_loss_price {
            order["stopLossOnFill"] = json!({"price": sl, "timeInForce": "GTC"})
        }

        if let Some(tp) = take_profit_price {
            order["takeProfitOnFill"] = json!({"price": tp, "timeInForce": "GTC"});
        }

        let body = json!({"order": order});

        let resp = self
            .http_client
            .post(&url)
            .bearer_auth(&self.api_key)
            .json(&body)
            .send()
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

    // --- Trades ---
    pub async fn modify_trade_stop_loss(
        &self,
        trade_id: &str,
        sl_price: &str,
    ) -> AppResult<serde_json::Value> {
        let url = format!(
            "{}/v3/accounts/{}/trades/{}/orders",
            self.base_url, self.account_id, trade_id
        );

        let body = json!({"stopLoss": {"price": sl_price, "timeInForce": "GTC"}});

        let resp = self
            .http_client
            .put(&url)
            .bearer_auth(&self.api_key)
            .json(&body)
            .send()
            .await
            .map_err(|e| AppError::Oanda(e.to_string()))?;

        let status = resp.status();
        let resp_body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| AppError::Oanda(format!("Failed to parse modify SL response: {}", e)))?;

        if !status.is_success() {
            let error_msg = resp_body["errorMessage"]
                .as_str()
                .unwrap_or("Unknown error");
            return Err(AppError::Oanda(format!(
                "Modify SL failed ({}): {}",
                status, error_msg
            )));
        }

        Ok(resp_body)
    }

    pub async fn replace_with_trailing_stop(
        &self,
        trade_id: &str,
        distance: &str,
    ) -> AppResult<serde_json::Value> {
        let url = format!(
            "{}/v3/accounts/{}/trades/{}/orders",
            self.base_url, self.account_id, trade_id
        );

        // Atomic: cancel SL+TP, create trailing SL, all in one call
        let body = serde_json::json!({
            "stopLoss": null,
            "takeProfit": null,
            "trailingStopLoss": { "distance": distance, "timeInForce": "GTC" }
        });

        let response = self
            .http_client
            .put(&url)
            .bearer_auth(&self.api_key)
            .json(&body)
            .send()
            .await
            .map_err(|e| AppError::Oanda(e.to_string()))?;

        let status = response.status();
        let resp_body: serde_json::Value = response.json().await.map_err(|e| {
            AppError::Oanda(format!(
                "Failed to parse replace with trailing response: {}",
                e
            ))
        })?;

        if !status.is_success() {
            let error_msg = resp_body["errorMessage"]
                .as_str()
                .unwrap_or("Unknown error");
            return Err(AppError::Oanda(format!(
                "OANDA replace with trailing failed ({}): {}",
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
            .http_client
            .get(&url)
            .bearer_auth(&self.api_key)
            .send()
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
            .http_client
            .put(&url)
            .bearer_auth(&self.api_key)
            .json(&body)
            .send()
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
            .http_client
            .get(&url)
            .bearer_auth(&self.api_key)
            .send()
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
            .http_client
            .get(&url)
            .bearer_auth(&self.api_key)
            .send()
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
            .http_client
            .get(&url)
            .bearer_auth(&self.api_key)
            .query(&[("id", since_id), ("type", "ORDER_FILL")])
            .send()
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
                        name: format!("Practice ({})", account.id),
                        account_type: "Practice".into(),
                        currency: account.currency,
                        cash: Some(cash),
                        market_value: None,
                        total_equity: Some(cash + unrealized),
                        buying_power,
                    }],
                }
            }
        }
    }
}
