use std::sync::Arc;
use std::time::Duration as StdDuration;

use chrono::NaiveDate;
use reqwest::Client;
use serde::de::DeserializeOwned;
use tokio::sync::Mutex;
use tokio::time::Instant;

use super::models::{AggBar, OptionContract, Page};
use crate::engine::types::Granularity;
use crate::error::{AppError, AppResult};

/// The vendor's per-request cap on rows for aggregates.
const AGG_PAGE_LIMIT: u32 = 50_000;
/// The vendor's per-request cap on rows for reference lists.
const REF_PAGE_LIMIT: u32 = 1_000;
/// Massive versions endpoints individually: aggregates are `v2`, reference
/// data is `v3`. The segment belongs to the endpoint, so it is pinned here.
const AGGREGATES_VERSION: &str = "v2";
const REFERENCE_VERSION: &str = "v3";

/// Which option contracts to list.
#[derive(Debug, Clone, PartialEq)]
pub struct ContractFilter {
    pub underlying: String,
    /// Inclusive expiry window.
    pub expires_from: NaiveDate,
    pub expires_to: NaiveDate,
    /// Inclusive strike window; `None` lists every strike.
    pub strikes: Option<(f64, f64)>,
    /// Include contracts that have already expired (needed to list a past
    /// chain; the vendor hides them by default).
    pub expired: bool,
    /// List the chain as it stood on this date (vendor default: today).
    pub as_of: Option<NaiveDate>,
}

#[derive(Debug, Clone)]
pub struct MassiveClient {
    http: Client,
    base_url: String,
    api_key: String,
    /// Minimum gap between requests, from the plan's calls-per-minute.
    spacing: StdDuration,
    /// When the previous request was sent; shared across clones so every
    /// caller observes the same spacing.
    last_call: Arc<Mutex<Option<Instant>>>,
}

impl MassiveClient {
    /// `calls_per_minute` is the plan limit (5 on the free plan; paid plans
    /// are unlimited, pass something large). Zero means no spacing.
    pub fn new(base_url: &str, api_key: &str, calls_per_minute: u32) -> AppResult<Self> {
        let http = Client::builder()
            .timeout(StdDuration::from_secs(30))
            .connect_timeout(StdDuration::from_secs(10))
            .build()
            .map_err(|e| AppError::Internal(format!("Failed to build Massive HTTP client: {e}")))?;

        Ok(Self {
            http,
            base_url: base_url.trim_end_matches('/').to_string(),
            api_key: api_key.to_string(),
            spacing: spacing_for(calls_per_minute),
            last_call: Arc::new(Mutex::new(None)),
        })
    }

    /// Vendor `(multiplier, timespan)` for one of our granularities.
    pub fn range_for(granularity: Granularity) -> (u32, &'static str) {
        match granularity {
            Granularity::M1 => (1, "minute"),
            Granularity::M5 => (5, "minute"),
            Granularity::M15 => (15, "minute"),
            Granularity::H1 => (1, "hour"),
            Granularity::H4 => (4, "hour"),
            Granularity::D => (1, "day"),
        }
    }

    /// First page URL for `ticker` at `granularity` over `[from, to]` (dates
    /// inclusive, New York trading days). Split-adjusted, oldest first. Works
    /// for stock tickers and `O:`-prefixed option tickers alike.
    pub fn aggregates_url(
        &self,
        ticker: &str,
        granularity: Granularity,
        from: NaiveDate,
        to: NaiveDate,
    ) -> String {
        let (multiplier, timespan) = Self::range_for(granularity);
        format!(
            "{}/{}/aggs/ticker/{}/range/{}/{}/{}/{}?adjusted=true&sort=asc&limit={}",
            self.base_url,
            AGGREGATES_VERSION,
            ticker,
            multiplier,
            timespan,
            from,
            to,
            AGG_PAGE_LIMIT
        )
    }

    /// First page URL of the option contracts matching `filter`.
    pub fn contracts_url(&self, filter: &ContractFilter) -> String {
        let mut url = format!(
            "{}/{}/reference/options/contracts?underlying_ticker={}&expiration_date.gte={}&expiration_date.lte={}&expired={}&order=asc&sort=expiration_date&limit={}",
            self.base_url,
            REFERENCE_VERSION,
            filter.underlying,
            filter.expires_from,
            filter.expires_to,
            filter.expired,
            REF_PAGE_LIMIT
        );
        if let Some((lo, hi)) = filter.strikes {
            url.push_str(&format!("&strike_price.gte={lo}&strike_price.lte={hi}"));
        }
        if let Some(as_of) = filter.as_of {
            url.push_str(&format!("&as_of={as_of}"));
        }
        url
    }

    /// All bars for the window, following `next_url` pages. Each page is one
    /// rate-limited request.
    pub async fn get_aggregates(
        &self,
        ticker: &str,
        granularity: Granularity,
        from: NaiveDate,
        to: NaiveDate,
    ) -> AppResult<Vec<AggBar>> {
        self.fetch_all(self.aggregates_url(ticker, granularity, from, to))
            .await
    }

    /// Every contract matching `filter`, following pages.
    pub async fn list_option_contracts(
        &self,
        filter: &ContractFilter,
    ) -> AppResult<Vec<OptionContract>> {
        self.fetch_all(self.contracts_url(filter)).await
    }

    async fn fetch_all<T: DeserializeOwned>(&self, first_url: String) -> AppResult<Vec<T>> {
        let mut url = first_url;
        let mut rows = Vec::new();
        loop {
            let page: Page<T> = self.fetch_page(&url).await?;
            rows.extend(page.results);
            match page.next_url {
                Some(next) => url = next,
                None => break,
            }
        }
        Ok(rows)
    }

    async fn fetch_page<T: DeserializeOwned>(&self, url: &str) -> AppResult<Page<T>> {
        self.throttle().await;

        let resp = self
            .http
            .get(url)
            .bearer_auth(&self.api_key)
            .send()
            .await
            .map_err(|e| AppError::Internal(format!("Massive request failed: {e}")))?;

        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| AppError::Internal(format!("Massive response unreadable: {e}")))?;

        Page::parse(status, &body)
    }

    /// Sleep until at least `spacing` has passed since the previous request,
    /// then claim this slot. The lock is held across the sleep on purpose:
    /// concurrent callers must queue, not race for the same slot.
    async fn throttle(&self) {
        if self.spacing.is_zero() {
            return;
        }
        let mut last = self.last_call.lock().await;
        let wait = wait_before_next_call(*last, Instant::now(), self.spacing);
        if !wait.is_zero() {
            tokio::time::sleep(wait).await;
        }
        *last = Some(Instant::now());
    }
}

/// Gap between calls that keeps a long loop under `calls_per_minute`, with a
/// little slack so a clock skew never produces a 429.
fn spacing_for(calls_per_minute: u32) -> StdDuration {
    if calls_per_minute == 0 {
        return StdDuration::ZERO;
    }
    StdDuration::from_millis(60_000 / u64::from(calls_per_minute) + 500)
}

/// How long to wait so that `now + wait` is at least `spacing` after the
/// previous call (zero when there was none or it is old enough).
fn wait_before_next_call(
    previous: Option<Instant>,
    now: Instant,
    spacing: StdDuration,
) -> StdDuration {
    match previous {
        Some(prev) => spacing.saturating_sub(now.duration_since(prev)),
        None => StdDuration::ZERO,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn client() -> MassiveClient {
        MassiveClient::new("https://api.massive.com/", "k", 5).unwrap()
    }

    #[test]
    fn aggregates_url_pins_v2_and_uses_vendor_range_names() {
        let url = client().aggregates_url(
            "SPY",
            Granularity::D,
            NaiveDate::from_ymd_opt(2024, 10, 21).unwrap(),
            NaiveDate::from_ymd_opt(2026, 10, 17).unwrap(),
        );
        assert_eq!(
            url,
            "https://api.massive.com/v2/aggs/ticker/SPY/range/1/day/2024-10-21/2026-10-17?adjusted=true&sort=asc&limit=50000"
        );
    }

    #[test]
    fn contracts_url_carries_every_filter() {
        let filter = ContractFilter {
            underlying: "SPY".into(),
            expires_from: NaiveDate::from_ymd_opt(2026, 10, 23).unwrap(),
            expires_to: NaiveDate::from_ymd_opt(2026, 12, 18).unwrap(),
            strikes: Some((600.0, 720.0)),
            expired: false,
            as_of: Some(NaiveDate::from_ymd_opt(2026, 10, 22).unwrap()),
        };
        assert_eq!(
            client().contracts_url(&filter),
            "https://api.massive.com/v3/reference/options/contracts?underlying_ticker=SPY&expiration_date.gte=2026-10-23&expiration_date.lte=2026-12-18&expired=false&order=asc&sort=expiration_date&limit=1000&strike_price.gte=600&strike_price.lte=720&as_of=2026-10-22"
        );
    }

    #[test]
    fn every_granularity_maps_to_a_vendor_range() {
        assert_eq!(MassiveClient::range_for(Granularity::M5), (5, "minute"));
        assert_eq!(MassiveClient::range_for(Granularity::H4), (4, "hour"));
        assert_eq!(MassiveClient::range_for(Granularity::D), (1, "day"));
    }

    #[test]
    fn calls_are_spaced_to_the_plan_limit() {
        let spacing = spacing_for(5);
        assert_eq!(spacing, StdDuration::from_millis(12_500));
        assert_eq!(spacing_for(0), StdDuration::ZERO);

        let now = Instant::now();
        assert_eq!(wait_before_next_call(None, now, spacing), StdDuration::ZERO);
        assert_eq!(
            wait_before_next_call(Some(now - StdDuration::from_secs(2)), now, spacing),
            spacing - StdDuration::from_secs(2)
        );
        assert_eq!(
            wait_before_next_call(Some(now - StdDuration::from_secs(60)), now, spacing),
            StdDuration::ZERO
        );
    }
}
