use reqwest::Client;
use serde_json::{json, Value};

use super::models::*;
use crate::error::{AppError, AppResult};

#[derive(Debug, Clone)]
pub struct QuestradeClient {
    http_client: Client,
    base_url: String,
    stream_url: String,
    api_key: String,
    account_id: String,
}

impl QuestradeClient {
    pub fn new(base_url: &str, stream_url: &str, api_key: &str, account_id: &str) -> Self {
        Self {
            http_client: Client::new(),
            base_url: base_url.to_string(),
            stream_url: stream_url.to_string(),
            api_key: api_key.to_string(),
            account_id: account_id.to_string(),
        }
    }

    pub async fn get_account(&self) -> AppResult<Account> {
        let url = format!("{}/v1/accounts/{}", self.base_url, self.account_id);
        let resp = self
            .http_client
            .get(&url)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .send()
            .await
            .map_err(|e| AppError::External(format!("HTTP request failed: {}", e)))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            return Err(AppError::External(format!(
                "Questrade API error (status {}): {}",
                status, text
            )));
        }

        let account_resp: AccountResponse = resp
            .json()
            .await
            .map_err(|e| AppError::External(format!("Failed to parse JSON response: {}", e)))?;

        Ok(account_resp.account)
    }
}