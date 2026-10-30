use std::collections::HashMap;
use std::time::Duration as StdDuration;

use chrono::{DateTime, Duration, NaiveDate, Utc};
use reqwest::{Client, Method};
use sqlx::PgPool;

use super::models::{
    AccountBalancesResponse, AccountsResponse, CandlesResponse, ChainExpiry, EquityCandle,
    OptionChainResponse, OptionQuote, OptionQuotesResponse, QuestradeAccount, QuoteResult,
    QuotesResponse, SymbolDetail, SymbolSearchResponse, SymbolsResponse, TokenResponse,
};
use crate::brokers::client::BrokerClient;
use crate::brokers::{BrokerAccount, BrokerKind, BrokerStatus};
use crate::engine::types::Granularity;
use crate::error::{AppError, AppResult};

const AUTH_URL: &str = "https://login.questrade.com/oauth2/token";

/// Option symbol IDs per quotes request. The documentation states no cap;
/// this keeps each request well under the response sizes the equity quotes
/// call is known to handle.
const OPTION_QUOTE_BATCH: usize = 100;

/// The longest a rate-limited request waits before its one retry. Questrade's
/// market-data limits are per second; a reset further off (the hourly
/// limit) isn't waited for, and the retry fails as the first did.
const MAX_RATE_LIMIT_WAIT: StdDuration = StdDuration::from_secs(5);

/// Tries at writing a rotated refresh token to the DB before giving up loudly.
const TOKEN_PERSIST_ATTEMPTS: u32 = 3;

/// How much of a 401 body is logged; Questrade's are a short code + message.
const LOGGED_401_CHARS: usize = 300;

#[derive(Clone)]
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

/// By hand so the refresh and access tokens never reach a log line.
impl std::fmt::Debug for QuestradeClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("QuestradeClient")
            .field("api_server", &self.api_server)
            .field("expires_at", &self.expires_at)
            .field("authenticated", &self.access_token.is_some())
            .finish_non_exhaustive()
    }
}

/// How an auth error starts when Questrade answered 4xx: it refused the
/// token itself, which no retry can fix (`is_token_refused`).
const TOKEN_REFUSED: &str = "Questrade refused the token";

/// Whether `error` is Questrade refusing the token (a 4xx from its auth
/// endpoint), not a network or server failure worth retrying.
pub fn is_token_refused(error: &AppError) -> bool {
    matches!(error, AppError::Internal(message) if message.starts_with(TOKEN_REFUSED))
}

impl QuestradeClient {
    /// Authenticate from the DB token row (the latest rotated refresh token),
    /// falling back to `env_token` when the DB has no row or Questrade rejects
    /// the DB token. Refresh tokens are single-use, so a dead DB token means
    /// the user pasted a fresh one into the env; an env token equal to the DB
    /// token is never retried. The successful token's rotation is persisted
    /// by `authenticate`. Returns None when no token is available.
    pub async fn connect(pool: &PgPool, env_token: Option<&str>) -> AppResult<Option<Self>> {
        let db_token: Option<String> =
            sqlx::query_scalar("SELECT refresh_token FROM questrade_tokens WHERE singleton = TRUE")
                .fetch_optional(pool)
                .await
                .map_err(|e| {
                    AppError::Internal(format!("DB error loading questrade token: {}", e))
                })?;

        let env_token = env_token.filter(|t| db_token.as_deref() != Some(*t));
        let candidates: Vec<String> = db_token
            .into_iter()
            .chain(env_token.map(str::to_string))
            .collect();

        let mut last_error = None;
        for (i, token) in candidates.into_iter().enumerate() {
            let mut client = Self::new(pool, token)?;
            match client.authenticate().await {
                Ok(()) => return Ok(Some(client)),
                Err(e) => {
                    tracing::warn!("Questrade token candidate {} rejected: {}", i + 1, e);
                    last_error = Some(e);
                }
            }
        }
        last_error.map_or(Ok(None), Err)
    }

    /// Authenticate with one token (pasted on the Accounts page), and only
    /// that one. The rotation is persisted by `authenticate`. Always
    /// `Some` on success; the `Option` matches `connect`.
    pub async fn connect_token(pool: &PgPool, token: String) -> AppResult<Option<Self>> {
        let mut client = Self::new(pool, token)?;
        client.authenticate().await?;
        Ok(Some(client))
    }

    pub(super) fn new(pool: &PgPool, refresh_token: String) -> AppResult<Self> {
        let http = Client::builder()
            .timeout(StdDuration::from_secs(30))
            .connect_timeout(StdDuration::from_secs(10))
            .build()
            .map_err(|e| {
                AppError::Internal(format!("Failed to build Questrade HTTP client: {}", e))
            })?;

        Ok(Self {
            http,
            pool: pool.clone(),
            refresh_token,
            access_token: None,
            api_server: None,
            expires_at: None,
            symbol_cache: HashMap::new(),
        })
    }

    /// Exchange the current refresh token for a fresh access token.
    /// Questrade invalidates the old refresh token as soon as this call
    /// succeeds, so the new tokens go into memory first (the process keeps
    /// working whatever happens next), then to the DB for the next start.
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
            let prefix = if status.is_client_error() {
                TOKEN_REFUSED
            } else {
                "Questrade auth error"
            };
            return Err(AppError::Internal(format!(
                "{prefix} ({}): {}",
                status,
                auth_error_text(&body, &self.refresh_token)
            )));
        }

        let token: TokenResponse = resp.json().await.map_err(|e| {
            AppError::Internal(format!("Failed to parse Questrade token response: {}", e))
        })?;

        let expires_at = Utc::now() + Duration::seconds(token.expires_in as i64);
        self.refresh_token = token.refresh_token;
        self.access_token = Some(token.access_token);
        self.api_server = Some(token.api_server);
        self.expires_at = Some(expires_at);
        tracing::info!("Questrade authenticated; token expires at {}", expires_at);

        self.persist_tokens().await;
        Ok(())
    }

    /// Write the in-memory tokens to the DB, retrying a few times. A failure
    /// is logged, not returned: the old refresh token is already dead, and
    /// the in-memory one keeps this process working until it next rotates.
    async fn persist_tokens(&self) {
        let mut last_error = None;
        for attempt in 1..=TOKEN_PERSIST_ATTEMPTS {
            let result = sqlx::query(
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
            )
            .bind(&self.refresh_token)
            .bind(&self.access_token)
            .bind(&self.api_server)
            .bind(self.expires_at)
            .execute(&self.pool)
            .await;
            match result {
                Ok(_) => return,
                Err(e) => {
                    tracing::warn!(
                        "Questrade token persist attempt {attempt}/{TOKEN_PERSIST_ATTEMPTS} failed: {e}"
                    );
                    last_error = Some(e);
                    if attempt < TOKEN_PERSIST_ATTEMPTS {
                        tokio::time::sleep(StdDuration::from_secs(attempt as u64)).await;
                    }
                }
            }
        }
        tracing::error!(
            "QUESTRADE REFRESH TOKEN NOT PERSISTED: {}. The rotated token lives only in \
             memory; the old DB token is dead, so the next restart needs a fresh token \
             in the env unless a later refresh persists.",
            last_error.map(|e| e.to_string()).unwrap_or_default()
        );
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

    /// `method` the API `path`, with `build` adding the query or body. Sent
    /// once more after a 401 (re-authenticating first) or a 429 (waiting out
    /// the rate limit first); any other failure, or a second one, is the
    /// error. The URL is built per send, so a retry after re-auth goes to
    /// the api_server the new token was issued for.
    async fn request(
        &mut self,
        method: Method,
        path: &str,
        build: impl Fn(reqwest::RequestBuilder) -> reqwest::RequestBuilder,
    ) -> AppResult<reqwest::Response> {
        self.ensure_authenticated().await?;

        let resp = self.send(&method, path, &build).await?;
        let resp = match resp.status() {
            reqwest::StatusCode::UNAUTHORIZED => {
                let body = resp.text().await.unwrap_or_default();
                let shown: String = body.chars().take(LOGGED_401_CHARS).collect();
                tracing::warn!(
                    "Questrade 401 on {path} (token expires at {:?}) — forcing re-auth and retrying; body: {shown}",
                    self.expires_at
                );
                self.authenticate().await?;
                self.send(&method, path, &build).await?
            }
            reqwest::StatusCode::TOO_MANY_REQUESTS => {
                let wait = rate_limit_wait(resp.headers(), Utc::now());
                tracing::warn!(
                    "Questrade 429 — waiting {wait:?} for the rate limit, then retrying"
                );
                tokio::time::sleep(wait).await;
                self.send(&method, path, &build).await?
            }
            _ => resp,
        };

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

    async fn send(
        &self,
        method: &Method,
        path: &str,
        build: impl Fn(reqwest::RequestBuilder) -> reqwest::RequestBuilder,
    ) -> AppResult<reqwest::Response> {
        let url = self.api_url(path)?;
        build(self.http.request(method.clone(), url))
            .header("Authorization", self.bearer()?)
            .send()
            .await
            .map_err(|e| AppError::Internal(format!("Questrade request failed: {}", e)))
    }

    pub async fn get_account_balances(
        &mut self,
        account_id: &str,
    ) -> AppResult<AccountBalancesResponse> {
        let path = format!("accounts/{}/balances", account_id);
        let resp = self.request(Method::GET, &path, |rb| rb).await?;

        resp.json()
            .await
            .map_err(|e| AppError::Internal(format!("Failed to parse Questrade balances: {}", e)))
    }

    pub async fn get_accounts(&mut self) -> AppResult<Vec<QuestradeAccount>> {
        let resp = self.request(Method::GET, "accounts", |rb| rb).await?;

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

        let resp = self
            .request(Method::GET, "symbols/search", |rb| {
                rb.query(&[("prefix", upper.as_str())])
            })
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

        // Exact match only, preferring a tradable listing. Never the first
        // prefix hit: callers record the id, and a near-miss (`RY` for
        // `RY.TO`) would silently price or identify the wrong security.
        let result = parsed
            .symbols
            .iter()
            .find(|s| s.symbol == upper && s.is_tradable)
            .or_else(|| parsed.symbols.iter().find(|s| s.symbol == upper))
            .ok_or_else(|| {
                AppError::NotFound(format!("Questrade has no exact match for {}", upper))
            })?;

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

    /// Questrade's interval name for one of our granularities.
    pub fn interval_for(granularity: Granularity) -> &'static str {
        match granularity {
            Granularity::M1 => "OneMinute",
            Granularity::M5 => "FiveMinutes",
            Granularity::M15 => "FifteenMinutes",
            Granularity::H1 => "OneHour",
            Granularity::H4 => "FourHours",
            Granularity::D => "OneDay",
        }
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

            let path = format!("markets/candles/{}", symbol_id);
            let result = self
                .request(Method::GET, &path, |rb| {
                    rb.query(&[
                        ("startTime", start_time.as_str()),
                        ("endTime", end_time.as_str()),
                        ("interval", interval),
                    ])
                })
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

        let ids = join_ids(symbol_ids);
        let resp = self
            .request(Method::GET, "markets/quotes", |rb| {
                rb.query(&[("ids", &ids)])
            })
            .await?;

        let parsed: QuotesResponse = resp
            .json()
            .await
            .map_err(|e| AppError::Internal(format!("Failed to parse Questrade quotes: {}", e)))?;

        Ok(parsed.quotes)
    }

    /// Fetch reference data (market cap, average volume, tick ladder, sector)
    /// for one or more symbol IDs.
    /// Questrade: GET /v1/symbols?ids=1234,5678
    pub async fn get_symbols(&mut self, symbol_ids: &[i64]) -> AppResult<Vec<SymbolDetail>> {
        if symbol_ids.is_empty() {
            return Ok(vec![]);
        }

        let ids = join_ids(symbol_ids);
        let resp = self
            .request(Method::GET, "symbols", |rb| rb.query(&[("ids", &ids)]))
            .await?;

        let parsed: SymbolsResponse = resp
            .json()
            .await
            .map_err(|e| AppError::Internal(format!("Failed to parse Questrade symbols: {}", e)))?;

        Ok(parsed.symbols)
    }

    /// The option chain on an underlying: every expiry and root with the
    /// strikes and their call/put symbol IDs.
    /// Questrade: GET /v1/symbols/{id}/options
    pub async fn get_option_chain(&mut self, symbol_id: i64) -> AppResult<Vec<ChainExpiry>> {
        let path = format!("symbols/{}/options", symbol_id);
        let resp = self.request(Method::GET, &path, |rb| rb).await?;

        let parsed: OptionChainResponse = resp.json().await.map_err(|e| {
            AppError::Internal(format!("Failed to parse Questrade option chain: {}", e))
        })?;

        Ok(parsed.option_chain)
    }

    /// Level 1 quotes with the exchange greeks for option symbol IDs, fetched
    /// in batches of `OPTION_QUOTE_BATCH`.
    /// Questrade: POST /v1/markets/quotes/options {"optionIds": [...]}
    pub async fn get_option_quotes(&mut self, option_ids: &[i64]) -> AppResult<Vec<OptionQuote>> {
        let mut quotes = Vec::with_capacity(option_ids.len());
        for batch in option_ids.chunks(OPTION_QUOTE_BATCH) {
            let body = serde_json::json!({ "optionIds": batch });
            let resp = self
                .request(Method::POST, "markets/quotes/options", |rb| rb.json(&body))
                .await?;

            let parsed: OptionQuotesResponse = resp.json().await.map_err(|e| {
                AppError::Internal(format!("Failed to parse Questrade option quotes: {}", e))
            })?;
            quotes.extend(parsed.option_quotes);
        }
        Ok(quotes)
    }
}

/// How long a 429 asks us to wait: until `X-RateLimit-Reset` (Unix seconds),
/// at least a moment and at most `MAX_RATE_LIMIT_WAIT`; a second without it.
fn rate_limit_wait(headers: &reqwest::header::HeaderMap, now: DateTime<Utc>) -> StdDuration {
    headers
        .get("X-RateLimit-Reset")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.trim().parse::<i64>().ok())
        .and_then(|reset| DateTime::from_timestamp(reset, 0))
        .map(|reset| (reset - now).to_std().unwrap_or_default())
        .unwrap_or(StdDuration::from_secs(1))
        .clamp(StdDuration::from_millis(250), MAX_RATE_LIMIT_WAIT)
}

/// A rejected token exchange's body as it may be logged or shown: short,
/// and never containing the token that was sent.
fn auth_error_text(body: &str, token: &str) -> String {
    let scrubbed = if token.is_empty() {
        body.to_string()
    } else {
        body.replace(token, "[token]")
    };
    let short: String = scrubbed.trim().chars().take(LOGGED_401_CHARS).collect();
    if short.is_empty() {
        "no message".to_string()
    } else {
        short
    }
}

/// Questrade's multi-id query format: "1234,5678".
fn join_ids(symbol_ids: &[i64]) -> String {
    symbol_ids
        .iter()
        .map(|id| id.to_string())
        .collect::<Vec<_>>()
        .join(",")
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
            let balances = match self.get_account_balances(&acct.number).await {
                Ok(b) => Some(b),
                Err(e) => {
                    tracing::warn!(
                        "Questrade balances for account {} unavailable: {e}",
                        acct.number
                    );
                    None
                }
            };
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

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use reqwest::header::{HeaderMap, HeaderValue};

    fn reset_at(secs: i64) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert("X-RateLimit-Reset", HeaderValue::from(secs));
        headers
    }

    #[test]
    fn only_a_refused_token_reads_as_refused() {
        let refused = AppError::Internal(format!("{TOKEN_REFUSED} (400 Bad Request): Bad Request"));
        assert!(is_token_refused(&refused));
        let down = AppError::Internal("Questrade auth error (503 Service Unavailable): ".into());
        assert!(!is_token_refused(&down));
        let network = AppError::Internal("Questrade auth request failed: timed out".into());
        assert!(!is_token_refused(&network));
    }

    #[tokio::test]
    async fn printing_a_client_never_shows_its_tokens() {
        let pool = PgPool::connect_lazy("postgres://localhost/unused").unwrap();
        let mut client = QuestradeClient::new(&pool, "refresh-secret".to_string()).unwrap();
        client.access_token = Some("access-secret".to_string());
        let shown = format!("{client:?}");
        assert!(!shown.contains("refresh-secret") && !shown.contains("access-secret"));
        assert!(shown.contains("authenticated: true"));
    }

    #[test]
    fn an_auth_error_never_carries_the_token() {
        let text = auth_error_text("Bad Request: token abc123 is invalid", "abc123");
        assert_eq!(text, "Bad Request: token [token] is invalid");
        assert_eq!(auth_error_text("  ", "abc123"), "no message");
        let long = "x".repeat(LOGGED_401_CHARS * 2);
        assert_eq!(
            auth_error_text(&long, "abc123").chars().count(),
            LOGGED_401_CHARS
        );
    }

    #[test]
    fn a_rate_limit_waits_until_the_reset_within_bounds() {
        let now = Utc.timestamp_opt(1_000_000, 0).unwrap();
        assert_eq!(
            rate_limit_wait(&reset_at(1_000_002), now),
            StdDuration::from_secs(2)
        );
        // Already reset: a moment, not zero.
        assert_eq!(
            rate_limit_wait(&reset_at(999_999), now),
            StdDuration::from_millis(250)
        );
        // The hourly limit: no long wait.
        assert_eq!(
            rate_limit_wait(&reset_at(1_003_600), now),
            MAX_RATE_LIMIT_WAIT
        );
        // No header: a second.
        assert_eq!(
            rate_limit_wait(&HeaderMap::new(), now),
            StdDuration::from_secs(1)
        );
    }
}
