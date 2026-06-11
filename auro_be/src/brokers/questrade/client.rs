use std::collections::HashMap;
use std::time::Duration as StdDuration;

use chrono::{DateTime, Duration, NaiveDate, Utc};
use reqwest::Client;
use sqlx::PgPool;

use super::models::{
    AccountBalancesResponse, AccountsResponse, CandlesResponse, EquityCandle, QuestradeAccount,
    QuoteResult, QuotesResponse, SymbolSearchResponse, TokenResponse,
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

        let http = Client::builder()
            .timeout(StdDuration::from_secs(30))
            .connect_timeout(StdDuration::from_secs(10))
            .build()
            .map_err(|e| {
                AppError::Internal(format!("Failed to build Questrade HTTP client: {}", e))
            })?;

        Ok(Some(Self {
            http,
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

    async fn request(&mut self, builder: reqwest::RequestBuilder) -> AppResult<reqwest::Response> {
        self.ensure_authenticated().await?;

        // Clone before send so we can retry once on 401.
        // try_clone returns None only for streaming bodies; all our requests are GET with no body.
        let retry = builder.try_clone();

        let resp = builder
            .header("Authorization", self.bearer()?)
            .send()
            .await
            .map_err(|e| AppError::Internal(format!("Questrade request failed: {}", e)))?;

        if resp.status() == reqwest::StatusCode::UNAUTHORIZED {
            if let Some(rb) = retry {
                tracing::warn!("Questrade 401 — forcing re-auth and retrying");
                self.authenticate().await?;
                let resp = rb
                    .header("Authorization", self.bearer()?)
                    .send()
                    .await
                    .map_err(|e| AppError::Internal(format!("Questrade retry failed: {}", e)))?;
                if !resp.status().is_success() {
                    let status = resp.status();
                    let body = resp.text().await.unwrap_or_default();
                    return Err(AppError::BrokerHttp {
                        broker: "Questrade",
                        status: status.as_u16(),
                        body,
                    });
                }
                return Ok(resp);
            }
        }

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(AppError::BrokerHttp {
                broker: "Questrade",
                status: status.as_u16(),
                body,
            });
        }
        Ok(resp)
    }

    pub async fn get_account_balances(
        &mut self,
        account_id: &str,
    ) -> AppResult<AccountBalancesResponse> {
        let url = self.api_url(&format!("accounts/{}/balances", account_id))?;
        let resp = self.request(self.http.get(&url)).await?;

        resp.json()
            .await
            .map_err(|e| AppError::Internal(format!("Failed to parse Questrade balances: {}", e)))
    }

    pub async fn get_accounts(&mut self) -> AppResult<Vec<QuestradeAccount>> {
        let url = self.api_url("accounts")?;
        let resp = self.request(self.http.get(&url)).await?;

        let parsed: AccountsResponse = resp.json().await.map_err(|e| {
            AppError::Internal(format!("Failed to parse Questrade accounts: {}", e))
        })?;

        Ok(parsed.accounts)
    }

    /// Resolve a ticker symbol to Questrade's numeric symbol ID.
    /// Result is cached in memory for the lifetime of the client.
    pub async fn search_symbol(&mut self, ticker: &str) -> AppResult<i64> {
        let upper = ticker.to_uppercase();
        if let Some(&id) = self.symbol_cache.get(&upper) {
            return Ok(id);
        }

        let url = self.api_url("symbols/search")?;
        let resp = self
            .request(self.http.get(&url).query(&[("prefix", upper.as_str())]))
            .await?;

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

        // Exact match + tradable is the happy path; fall back to exact, then first result.
        let result = parsed
            .symbols
            .iter()
            .find(|s| s.symbol == upper && s.is_tradable)
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

    /// Max days per request that keeps bar count safely under Questrade's 20k limit.
    fn interval_chunk_days(interval: &str) -> i64 {
        match interval {
            "OneMinute" => 20,
            "TwoMinutes" | "ThreeMinutes" | "FourMinutes" => 40,
            "FiveMinutes" | "TenMinutes" => 90,
            "FifteenMinutes" | "TwentyMinutes" | "HalfHour" => 180,
            _ => 365, // OneHour, FourHours, OneDay, etc.
        }
    }

    /// Fetch candles for a resolved symbol ID, paginating automatically so that
    /// any date range works regardless of Questrade's 20k-bar per-request cap.
    /// `start` / `end` are "YYYY-MM-DD"; `interval` is a Questrade interval string
    /// (e.g. "OneDay", "OneHour", "FiveMinutes").
    ///
    /// Pagination walks newest → oldest: Questrade returns 400 for ranges older
    /// than its data-retention window, and walking backward means hitting that
    /// boundary truncates the result instead of discarding the newer chunks.
    /// A 400 on the very first (newest) chunk is a real error and propagates.
    pub async fn get_candles(
        &mut self,
        symbol_id: i64,
        start: &str,
        end: &str,
        interval: &str,
    ) -> AppResult<Vec<EquityCandle>> {
        let chunk_days = Self::interval_chunk_days(interval);

        let start_date = NaiveDate::parse_from_str(start, "%Y-%m-%d")
            .map_err(|e| AppError::Internal(format!("Invalid start date '{}': {}", start, e)))?;
        let end_date = NaiveDate::parse_from_str(end, "%Y-%m-%d")
            .map_err(|e| AppError::Internal(format!("Invalid end date '{}': {}", end, e)))?;

        let mut all_candles: Vec<EquityCandle> = Vec::new();
        let mut chunk_end = end_date;
        let mut fetched_any_chunk = false;

        while chunk_end >= start_date {
            let chunk_start = {
                let candidate = chunk_end - Duration::days(chunk_days - 1);
                if candidate > start_date {
                    candidate
                } else {
                    start_date
                }
            };

            // Questrade expects RFC3339 with fractional seconds; -05:00 aligns TSX daily bars.
            let start_time = format!("{}T00:00:00.000000-05:00", chunk_start);
            let end_time = format!("{}T23:59:59.999999-05:00", chunk_end);

            let url = self.api_url(&format!("markets/candles/{}", symbol_id))?;
            let result = self
                .request(self.http.get(&url).query(&[
                    ("startTime", start_time.as_str()),
                    ("endTime", end_time.as_str()),
                    ("interval", interval),
                ]))
                .await;

            let resp = match result {
                Err(e @ AppError::BrokerHttp { status: 400, .. }) if fetched_any_chunk => {
                    tracing::info!(
                        "Questrade candles {}..{} hit data-retention boundary ({}); stopping pagination",
                        chunk_start, chunk_end, e
                    );
                    break;
                }
                Err(e) => return Err(e),
                Ok(r) => r,
            };
            fetched_any_chunk = true;

            let parsed: CandlesResponse = resp
                .json()
                .await
                .map_err(|e| AppError::Internal(format!("Failed to parse candles: {}", e)))?;

            tracing::debug!(
                "Questrade candles symbolId={} interval={} {}..{}: {} bars",
                symbol_id,
                interval,
                chunk_start,
                chunk_end,
                parsed.candles.len()
            );

            all_candles.extend(parsed.candles.into_iter().map(|c| EquityCandle {
                time: c.start,
                open: c.open,
                high: c.high,
                low: c.low,
                close: c.close,
                volume: c.volume,
                vwap: c.vwap,
            }));

            chunk_end = chunk_start - Duration::days(1);
        }

        // ISO 8601 strings sort lexicographically; dedup handles any chunk-boundary overlap.
        all_candles.sort_by(|a, b| a.time.cmp(&b.time));
        all_candles.dedup_by(|a, b| a.time == b.time);

        Ok(all_candles)
    }

    /// Fetch current quotes for one or more symbol IDs.
    /// Questrade: GET /v1/markets/quotes?ids=1234,5678
    pub async fn get_quotes(&mut self, symbol_ids: &[i64]) -> AppResult<Vec<QuoteResult>> {
        if symbol_ids.is_empty() {
            return Ok(vec![]);
        }

        let ids_str = symbol_ids
            .iter()
            .map(|id| id.to_string())
            .collect::<Vec<_>>()
            .join(",");

        let url = self.api_url("markets/quotes")?;
        let resp = self
            .request(self.http.get(&url).query(&[("ids", ids_str.as_str())]))
            .await?;

        let parsed: QuotesResponse = resp
            .json()
            .await
            .map_err(|e| AppError::Internal(format!("Failed to parse Questrade quotes: {}", e)))?;

        Ok(parsed.quotes)
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
