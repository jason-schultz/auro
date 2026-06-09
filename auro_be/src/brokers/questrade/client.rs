use std::collections::HashMap;

use chrono::{DateTime, Duration, Utc};
use reqwest::Client;
use sqlx::PgPool;

use super::models::{
    AccountBalancesResponse, AccountsResponse, CandlesResponse, EquityCandle, QuestradeAccount,
    SymbolSearchResponse, TokenResponse,
};
use crate::brokers::client::BrokerClient;
use crate::brokers::{BrokerAccount, BrokerKind, BrokerStatus};
use crate::error::{AppError, AppResult};

const AUTH_URL: &str = "https://login.questrade.com/oauth2/token";

#[derive(Debug, Clone)]
pub struct QuestradeClient {
    http: Client,
    pool: PgPool,
    refresh_token: String,
    access_token: Option<String>,
    api_server: Option<String>,
    expires_at: Option<DateTime<Utc>>,
    /// ticker (uppercase) → Questrade numeric symbol ID; populated on first search
    symbol_cache: HashMap<String, i64>,
}

impl QuestradeClient {
    /// Load the client from the DB token row, falling back to `env_token` if
    /// the DB has no row. Seeds the DB from `env_token` when used as fallback.
    /// Returns None when no token is available from either source.
    pub async fn from_db_or_env(pool: &PgPool, env_token: Option<&str>) -> AppResult<Option<Self>> {
        let db_token = sqlx::query_scalar!(
            "SELECT refresh_token FROM questrade_tokens WHERE singleton = TRUE"
        )
        .fetch_optional(pool)
        .await
        .map_err(|e| AppError::Internal(format!("DB error loading questrade token: {}", e)))?;

        let refresh_token = match (db_token, env_token) {
            (Some(t), _) => t,
            (None, Some(t)) => {
                sqlx::query!(
                    "INSERT INTO questrade_tokens (refresh_token) VALUES ($1)",
                    t
                )
                .execute(pool)
                .await
                .map_err(|e| {
                    AppError::Internal(format!("DB error seeding questrade token: {}", e))
                })?;
                t.to_string()
            }
            (None, None) => return Ok(None),
        };

        Ok(Some(Self {
            http: Client::new(),
            pool: pool.clone(),
            refresh_token,
            access_token: None,
            api_server: None,
            expires_at: None,
            symbol_cache: HashMap::new(),
        }))
    }

    /// Exchange the current refresh token for a fresh access token.
    /// Persists the new refresh token to DB immediately — the old one is
    /// invalidated by Questrade as soon as this call succeeds.
    pub async fn authenticate(&mut self) -> AppResult<()> {
        let params = [
            ("grant_type", "refresh_token"),
            ("refresh_token", &self.refresh_token),
        ];

        let resp = self
            .http
            .post(AUTH_URL)
            .form(&params)
            .send()
            .await
            .map_err(|e| AppError::Internal(format!("Questrade auth request failed: {}", e)))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(AppError::Internal(format!(
                "Questrade auth error ({}): {}",
                status, body
            )));
        }

        let token: TokenResponse = resp.json().await.map_err(|e| {
            AppError::Internal(format!("Failed to parse Questrade token response: {}", e))
        })?;

        let expires_at = Utc::now() + Duration::seconds(token.expires_in as i64);

        // Persist the new tokens before updating self — if DB write fails we
        // haven't thrown away the in-memory state yet.
        sqlx::query!(
            r#"
            INSERT INTO questrade_tokens (singleton, refresh_token, access_token, api_server, expires_at, updated_at)
            VALUES (TRUE, $1, $2, $3, $4, NOW())
            ON CONFLICT (singleton) DO UPDATE
                SET refresh_token = EXCLUDED.refresh_token,
                    access_token  = EXCLUDED.access_token,
                    api_server    = EXCLUDED.api_server,
                    expires_at    = EXCLUDED.expires_at,
                    updated_at    = NOW()
            "#,
            token.refresh_token,
            token.access_token,
            token.api_server,
            expires_at,
        )
        .execute(&self.pool)
        .await
        .map_err(|e| AppError::Internal(format!("DB error persisting questrade tokens: {}", e)))?;

        self.refresh_token = token.refresh_token;
        self.access_token = Some(token.access_token);
        self.api_server = Some(token.api_server);
        self.expires_at = Some(expires_at);

        tracing::info!("Questrade authenticated; token expires at {}", expires_at);
        Ok(())
    }

    /// Refresh if the access token is missing or within 60 seconds of expiry.
    async fn ensure_authenticated(&mut self) -> AppResult<()> {
        let needs_refresh = match self.expires_at {
            None => true,
            Some(exp) => Utc::now() + Duration::seconds(60) >= exp,
        };
        if needs_refresh {
            self.authenticate().await?;
        }
        Ok(())
    }

    fn bearer(&self) -> AppResult<String> {
        self.access_token
            .as_deref()
            .map(|t| format!("Bearer {}", t))
            .ok_or_else(|| AppError::Internal("Questrade: no access token in memory".into()))
    }

    fn api_url(&self, path: &str) -> AppResult<String> {
        let server = self
            .api_server
            .as_deref()
            .ok_or_else(|| AppError::Internal("Questrade: no api_server in memory".into()))?;
        // api_server already has a trailing slash
        Ok(format!("{}v1/{}", server, path))
    }

    pub async fn get_account_balances(
        &mut self,
        account_id: &str,
    ) -> AppResult<AccountBalancesResponse> {
        self.ensure_authenticated().await?;

        let url = self.api_url(&format!("accounts/{}/balances", account_id))?;
        let resp = self
            .http
            .get(&url)
            .header("Authorization", self.bearer()?)
            .send()
            .await
            .map_err(|e| {
                AppError::Internal(format!("Questrade get_account_balances failed: {}", e))
            })?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(AppError::Internal(format!(
                "Questrade balances error ({}): {}",
                status, body
            )));
        }

        resp.json()
            .await
            .map_err(|e| AppError::Internal(format!("Failed to parse Questrade balances: {}", e)))
    }

    pub async fn get_accounts(&mut self) -> AppResult<Vec<QuestradeAccount>> {
        self.ensure_authenticated().await?;

        let url = self.api_url("accounts")?;
        let resp = self
            .http
            .get(&url)
            .header("Authorization", self.bearer()?)
            .send()
            .await
            .map_err(|e| AppError::Internal(format!("Questrade get_accounts failed: {}", e)))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(AppError::Internal(format!(
                "Questrade accounts error ({}): {}",
                status, body
            )));
        }

        let parsed: AccountsResponse = resp.json().await.map_err(|e| {
            AppError::Internal(format!("Failed to parse Questrade accounts: {}", e))
        })?;

        Ok(parsed.accounts)
    }

    /// Resolve a ticker symbol to Questrade's numeric symbol ID.
    /// Prefers an exact match on TSX; falls back to any exchange.
    /// Result is cached in memory for the lifetime of the client.
    pub async fn search_symbol(&mut self, ticker: &str) -> AppResult<i64> {
        let upper = ticker.to_uppercase();
        if let Some(&id) = self.symbol_cache.get(&upper) {
            return Ok(id);
        }

        self.ensure_authenticated().await?;

        let url = self.api_url("symbols/search")?;
        let resp = self
            .http
            .get(&url)
            .header("Authorization", self.bearer()?)
            .query(&[("prefix", &upper)])
            .send()
            .await
            .map_err(|e| AppError::Internal(format!("Questrade symbol search failed: {}", e)))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(AppError::Internal(format!(
                "Questrade symbol search error ({}): {}",
                status, body
            )));
        }

        let parsed: SymbolSearchResponse = resp
            .json()
            .await
            .map_err(|e| AppError::Internal(format!("Failed to parse symbol search: {}", e)))?;

        // Log all candidates for exchange-mismatch diagnosis
        for s in &parsed.symbols {
            tracing::info!(
                "symbol search candidate: {} symbolId={} exchange={} currency={} tradable={} quotable={}",
                s.symbol, s.symbol_id, s.listing_exchange, s.currency, s.is_tradable, s.is_quotable
            );
        }

        // Prefer: exact + TSX + tradable → exact + TSX → exact + tradable → exact → first
        let result = parsed
            .symbols
            .iter()
            .find(|s| s.symbol == upper && s.listing_exchange == "TSX" && s.is_tradable)
            .or_else(|| {
                parsed
                    .symbols
                    .iter()
                    .find(|s| s.symbol == upper && s.listing_exchange == "TSX")
            })
            .or_else(|| {
                parsed
                    .symbols
                    .iter()
                    .find(|s| s.symbol == upper && s.is_tradable)
            })
            .or_else(|| parsed.symbols.iter().find(|s| s.symbol == upper))
            .or_else(|| parsed.symbols.first())
            .ok_or_else(|| AppError::Internal(format!("Symbol not found: {}", upper)))?;

        tracing::info!(
            "Resolved {} → symbolId={} exchange={} currency={} tradable={}",
            upper,
            result.symbol_id,
            result.listing_exchange,
            result.currency,
            result.is_tradable
        );

        self.symbol_cache.insert(upper, result.symbol_id);
        Ok(result.symbol_id)
    }

    /// Fetch daily (or other interval) candles for a resolved symbol ID.
    /// `start` / `end` are "YYYY-MM-DD"; `interval` is a Questrade interval string
    /// (e.g. "OneDay", "OneHour", "FifteenMinutes").
    pub async fn get_candles(
        &mut self,
        symbol_id: i64,
        start: &str,
        end: &str,
        interval: &str,
    ) -> AppResult<Vec<EquityCandle>> {
        self.ensure_authenticated().await?;

        // Questrade expects RFC3339 with fractional seconds; use Eastern time so
        // TSX daily bars are aligned correctly (EDT = -04:00 most of the year).
        let start_time = format!("{}T00:00:00.000000-05:00", start);
        let end_time = format!("{}T23:59:59.999999-05:00", end);

        let url = self.api_url(&format!("markets/candles/{}", symbol_id))?;
        let resp = self
            .http
            .get(&url)
            .header("Authorization", self.bearer()?)
            .query(&[
                ("startTime", start_time.as_str()),
                ("endTime", end_time.as_str()),
                ("interval", interval),
            ])
            .send()
            .await
            .map_err(|e| AppError::Internal(format!("Questrade get_candles failed: {}", e)))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(AppError::Internal(format!(
                "Questrade candles error ({}): {}",
                status, body
            )));
        }

        let parsed: CandlesResponse = resp
            .json()
            .await
            .map_err(|e| AppError::Internal(format!("Failed to parse candles: {}", e)))?;

        Ok(parsed
            .candles
            .into_iter()
            .map(|c| EquityCandle {
                time: c.start,
                open: c.open,
                high: c.high,
                low: c.low,
                close: c.close,
                volume: c.volume,
                vwap: c.vwap,
            })
            .collect())
    }
}

impl BrokerClient for QuestradeClient {
    async fn broker_status(&mut self) -> BrokerStatus {
        let accounts = match self.get_accounts().await {
            Err(e) => {
                return BrokerStatus {
                    broker: BrokerKind::Questrade,
                    display_name: "Questrade",
                    connected: false,
                    error: Some(e.to_string()),
                    accounts: vec![],
                }
            }
            Ok(a) => a,
        };

        let mut broker_accounts = Vec::with_capacity(accounts.len());
        for acct in &accounts {
            let balances = self.get_account_balances(&acct.number).await.ok();
            let combined = balances.as_ref().and_then(|b| b.combined_balances.first());
            broker_accounts.push(BrokerAccount {
                id: acct.number.clone(),
                name: format!("{} ({})", acct.account_type, acct.number),
                account_type: acct.account_type.clone(),
                currency: combined
                    .map(|b| b.currency.clone())
                    .unwrap_or_else(|| "CAD".into()),
                cash: combined.map(|b| b.cash),
                market_value: combined.map(|b| b.market_value),
                total_equity: combined.map(|b| b.total_equity),
                buying_power: combined.map(|b| b.buying_power),
            });
        }

        BrokerStatus {
            broker: BrokerKind::Questrade,
            display_name: "Questrade",
            connected: true,
            error: None,
            accounts: broker_accounts,
        }
    }
}
