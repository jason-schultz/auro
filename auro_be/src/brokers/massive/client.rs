use std::sync::Arc;
use std::time::Duration as StdDuration;

use chrono::NaiveDate;
use reqwest::Client;
use tokio::sync::Mutex;
use tokio::time::Instant;

use super::models::{AggBar, AggregatesResponse};
use crate::engine::types::Granularity;
use crate::error::{AppError, AppResult};

/// The free plan allows five requests a minute; spacing calls this far apart
/// keeps a long symbol loop under it without ever seeing a 429.
const MIN_CALL_SPACING: StdDuration = StdDuration::from_millis(12_500);
/// The vendor's per-request cap on bars.
const PAGE_LIMIT: u32 = 50_000;
/// Massive versions endpoints individually: aggregates are `v2`, reference
/// data is `v3`. The segment belongs to the endpoint, so it is pinned here.
const AGGREGATES_VERSION: &str = "v2";

#[derive(Debug, Clone)]
pub struct MassiveClient {
    http: Client,
    base_url: String,
    api_key: String,
    /// When the previous request was sent; shared across clones so every
    /// caller observes the same spacing.
    last_call: Arc<Mutex<Option<Instant>>>,
}

impl MassiveClient {
    pub fn new(base_url: &str, api_key: &str) -> AppResult<Self> {
        let http = Client::builder()
            .timeout(StdDuration::from_secs(30))
            .connect_timeout(StdDuration::from_secs(10))
            .build()
            .map_err(|e| AppError::Internal(format!("Failed to build Massive HTTP client: {e}")))?;

        Ok(Self {
            http,
            base_url: base_url.trim_end_matches('/').to_string(),
            api_key: api_key.to_string(),
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
    /// inclusive, New York trading days). Split-adjusted, oldest first.
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
            self.base_url, AGGREGATES_VERSION, ticker, multiplier, timespan, from, to, PAGE_LIMIT
        )
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
        let mut url = self.aggregates_url(ticker, granularity, from, to);
        let mut bars = Vec::new();

        loop {
            let page = self.fetch_page(&url).await?;
            bars.extend(page.results);
            match page.next_url {
                Some(next) => url = next,
                None => break,
            }
        }

        Ok(bars)
    }

    async fn fetch_page(&self, url: &str) -> AppResult<AggregatesResponse> {
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

        let page: AggregatesResponse = serde_json::from_str(&body).map_err(|e| {
            AppError::Internal(format!(
                "Massive response (HTTP {status}) not understood: {e}: {}",
                body.chars().take(200).collect::<String>()
            ))
        })?;

        match page.status.as_str() {
            "OK" | "DELAYED" => Ok(page),
            other => Err(AppError::Internal(format!(
                "Massive {other}: {}",
                page.error.or(page.message).unwrap_or_default()
            ))),
        }
    }

    /// Sleep until at least `MIN_CALL_SPACING` has passed since the previous
    /// request, then claim this slot. The lock is held across the sleep on
    /// purpose: concurrent callers must queue, not race for the same slot.
    async fn throttle(&self) {
        let mut last = self.last_call.lock().await;
        let wait = wait_before_next_call(*last, Instant::now());
        if !wait.is_zero() {
            tokio::time::sleep(wait).await;
        }
        *last = Some(Instant::now());
    }
}

/// How long to wait so that `now + wait` is at least `MIN_CALL_SPACING`
/// after the previous call (zero when there was none or it is old enough).
fn wait_before_next_call(previous: Option<Instant>, now: Instant) -> StdDuration {
    match previous {
        Some(prev) => MIN_CALL_SPACING.saturating_sub(now.duration_since(prev)),
        None => StdDuration::ZERO,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn client() -> MassiveClient {
        MassiveClient::new("https://api.massive.com/", "k").unwrap()
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
    fn every_granularity_maps_to_a_vendor_range() {
        assert_eq!(MassiveClient::range_for(Granularity::M5), (5, "minute"));
        assert_eq!(MassiveClient::range_for(Granularity::H4), (4, "hour"));
        assert_eq!(MassiveClient::range_for(Granularity::D), (1, "day"));
    }

    #[test]
    fn calls_are_spaced_to_the_plan_limit() {
        let now = Instant::now();
        assert_eq!(wait_before_next_call(None, now), StdDuration::ZERO);
        assert_eq!(
            wait_before_next_call(Some(now - StdDuration::from_secs(2)), now),
            MIN_CALL_SPACING - StdDuration::from_secs(2)
        );
        assert_eq!(
            wait_before_next_call(Some(now - StdDuration::from_secs(60)), now),
            StdDuration::ZERO
        );
    }
}
