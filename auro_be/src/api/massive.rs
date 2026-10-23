use axum::extract::State;
use axum::Json;
use chrono::{DateTime, Duration, NaiveDate, Utc};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::brokers::massive::client::ContractFilter;
use crate::brokers::massive::models::AggBar;
use crate::db::repositories::candles as candles_repo;
use crate::db::repositories::options::{self as options_repo, OptionBarRow};
use crate::engine::types::{Candle, CandleRow, Granularity};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

/// The free plan serves roughly two years of history; anything longer is a
/// request mistake, not a backfill.
const MAX_PERSIST_DAYS: i64 = 800;

fn default_persist_days() -> i64 {
    5
}

#[derive(Debug, Deserialize)]
pub struct PersistCandles {
    pub symbol: String,
    /// Our granularity name ("D", "M5", ...).
    pub granularity: String,
    /// Calendar days back from today to (re)fetch. Overlaps are harmless —
    /// the upsert overwrites identical rows — so a scheduler can pull a few
    /// days each run and a one-off can pull the whole plan window.
    #[serde(default = "default_persist_days")]
    pub days: i64,
}

/// Fetch `days` of `symbol` bars from Massive and upsert the completed ones
/// into `candles`. Same contract as the Questrade persist endpoint; this is
/// the US-equity source, Questrade stays the Canadian one.
pub async fn persist_candles(
    State(state): State<AppState>,
    Json(body): Json<PersistCandles>,
) -> AppResult<Json<Value>> {
    let Some(massive) = state.massive.as_ref() else {
        return Err(AppError::Internal("Massive not configured".into()));
    };
    let granularity: Granularity = body.granularity.parse().map_err(AppError::BadRequest)?;
    if !(1..=MAX_PERSIST_DAYS).contains(&body.days) {
        return Err(AppError::BadRequest(format!(
            "days must be in 1..={MAX_PERSIST_DAYS}, got {}",
            body.days
        )));
    }

    let symbol = body.symbol.trim().to_uppercase();
    let now = Utc::now();
    let from = (now - Duration::days(body.days)).date_naive();
    let to = now.date_naive();

    let raw = massive
        .get_aggregates(&symbol, granularity, from, to)
        .await?;

    // Only bars that have fully closed: a run during the session must not
    // store a still-forming bar that the next run would see differently.
    let rows = completed_rows(&raw, &symbol, granularity, now)?;

    let stored = candles_repo::upsert_candles(&state.db, &rows)
        .await
        .map_err(AppError::Database)?;
    tracing::info!(
        "Persisted {} Massive {} {} candles ({} days)",
        stored,
        symbol,
        granularity,
        body.days
    );

    Ok(Json(json!({
        "symbol": symbol,
        "granularity": granularity.as_str(),
        "days": body.days,
        "candles_fetched": raw.len(),
        "candles_stored": stored,
        "first": rows.first().map(|r| r.candle.time),
        "last": rows.last().map(|r| r.candle.time),
    })))
}

fn completed_rows(
    bars: &[AggBar],
    symbol: &str,
    granularity: Granularity,
    now: chrono::DateTime<Utc>,
) -> AppResult<Vec<CandleRow>> {
    Ok(bars
        .iter()
        .map(Candle::try_from)
        .collect::<AppResult<Vec<_>>>()?
        .into_iter()
        .filter(|c| completes_at(c.time, granularity) <= now)
        .map(|candle| CandleRow {
            instrument: symbol.to_string(),
            granularity,
            candle,
        })
        .collect())
}

/// When a bar stops changing. Intraday bars are final one bar after they
/// open. Massive stamps daily bars at midnight New York and keeps updating
/// them through extended hours, which end 20:00 New York, 20 hours later, so
/// the nightly 01:30 UTC run sees the day that just closed.
fn completes_at(open: DateTime<Utc>, granularity: Granularity) -> DateTime<Utc> {
    match granularity {
        Granularity::D => open + Duration::hours(20),
        other => open + Duration::minutes(other.minutes()),
    }
}

// --- Options ---
//
// Phase 1 plumbing: the chain near the money for the next weeks, kept
// current nightly by Opus. Bars come one vendor call per contract, which the
// free plan's five-a-minute limit makes slow; the two-year history load is a
// separate flat-file path on a paid plan.

fn default_max_days_to_expiry() -> i64 {
    60
}

fn default_strike_band_pct() -> f64 {
    0.15
}

#[derive(Debug, Deserialize)]
pub struct SyncContracts {
    pub underlying: String,
    /// Expiries from today out to this many calendar days.
    #[serde(default = "default_max_days_to_expiry")]
    pub max_days_to_expiry: i64,
    /// Strikes within this fraction of the underlying's last close.
    #[serde(default = "default_strike_band_pct")]
    pub strike_band_pct: f64,
}

#[derive(Debug, Deserialize)]
pub struct PersistOptionBars {
    pub underlying: String,
    /// Calendar days back to (re)fetch per contract.
    #[serde(default = "default_persist_days")]
    pub days: i64,
    #[serde(default = "default_max_days_to_expiry")]
    pub max_days_to_expiry: i64,
    #[serde(default = "default_strike_band_pct")]
    pub strike_band_pct: f64,
}

/// Strike window around `spot`.
fn strike_band(spot: f64, pct: f64) -> (f64, f64) {
    (spot * (1.0 - pct), spot * (1.0 + pct))
}

/// The underlying's last stored daily close; the stock bars job must have
/// run for it first.
async fn underlying_spot(state: &AppState, underlying: &str) -> AppResult<f64> {
    candles_repo::latest_close(&state.db, underlying, Granularity::D)
        .await
        .map_err(AppError::Database)?
        .ok_or_else(|| {
            AppError::BadRequest(format!(
                "no daily bars stored for {underlying}; persist its Massive candles first"
            ))
        })
}

fn validate_band_and_window(pct: f64, max_days: i64) -> AppResult<()> {
    if !(0.0..=1.0).contains(&pct) {
        return Err(AppError::BadRequest(format!(
            "strike_band_pct must be in 0..=1, got {pct}"
        )));
    }
    if !(1..=MAX_PERSIST_DAYS).contains(&max_days) {
        return Err(AppError::BadRequest(format!(
            "max_days_to_expiry must be in 1..={MAX_PERSIST_DAYS}, got {max_days}"
        )));
    }
    Ok(())
}

/// Fetch the contracts on `underlying` expiring within the window and
/// striking within the band, and upsert them into `option_contracts`.
pub async fn sync_option_contracts(
    State(state): State<AppState>,
    Json(body): Json<SyncContracts>,
) -> AppResult<Json<Value>> {
    let Some(massive) = state.massive.as_ref() else {
        return Err(AppError::Internal("Massive not configured".into()));
    };
    validate_band_and_window(body.strike_band_pct, body.max_days_to_expiry)?;
    let underlying = body.underlying.trim().to_uppercase();
    let spot = underlying_spot(&state, &underlying).await?;
    let now = Utc::now();
    let (expires_from, expires_to) = expiry_window(now.date_naive(), body.max_days_to_expiry);
    let filter = ContractFilter {
        underlying: underlying.clone(),
        expires_from,
        expires_to,
        strikes: Some(strike_band(spot, body.strike_band_pct)),
        expired: false,
        as_of: None,
    };

    let contracts = massive.list_option_contracts(&filter).await?;
    let stored = options_repo::upsert_contracts(&state.db, &contracts, now)
        .await
        .map_err(AppError::Database)?;
    tracing::info!(
        "Synced {} {} option contracts (spot {:.2}, ±{:.0}%, {} days)",
        stored,
        underlying,
        spot,
        body.strike_band_pct * 100.0,
        body.max_days_to_expiry
    );
    Ok(Json(json!({
        "underlying": underlying,
        "spot": spot,
        "expires_from": filter.expires_from,
        "expires_to": filter.expires_to,
        "strikes": filter.strikes,
        "contracts_fetched": contracts.len(),
        "contracts_stored": stored,
    })))
}

/// After this many contracts in a row fail, the plan or key is the problem,
/// not the contract; stop instead of burning the rate limit on the rest.
const MAX_CONSECUTIVE_FAILURES: usize = 3;

/// Fetch `days` of daily bars for every stored contract on `underlying`
/// that is live (or expired within the window) and near the money, and
/// upsert the completed ones into `option_bars`.
pub async fn persist_option_bars(
    State(state): State<AppState>,
    Json(body): Json<PersistOptionBars>,
) -> AppResult<Json<Value>> {
    let Some(massive) = state.massive.as_ref() else {
        return Err(AppError::Internal("Massive not configured".into()));
    };
    validate_band_and_window(body.strike_band_pct, body.max_days_to_expiry)?;
    if !(1..=MAX_PERSIST_DAYS).contains(&body.days) {
        return Err(AppError::BadRequest(format!(
            "days must be in 1..={MAX_PERSIST_DAYS}, got {}",
            body.days
        )));
    }
    let underlying = body.underlying.trim().to_uppercase();
    let spot = underlying_spot(&state, &underlying).await?;
    let now = Utc::now();
    let today = now.date_naive();
    let from = today - Duration::days(body.days);

    // Contracts that expired inside the window still have bars to collect.
    let contracts = options_repo::list_contracts(
        &state.db,
        &underlying,
        from,
        expiry_window(today, body.max_days_to_expiry).1,
        Some(strike_band(spot, body.strike_band_pct)),
    )
    .await
    .map_err(AppError::Database)?;

    let mut rows: Vec<OptionBarRow> = Vec::new();
    let mut fetched = 0usize;
    let mut failed: Vec<String> = Vec::new();
    let mut consecutive_failures = 0usize;
    for contract in &contracts {
        let to = today.min(contract.expiration_date);
        match massive
            .get_aggregates(&contract.ticker, Granularity::D, from, to)
            .await
        {
            Ok(bars) => {
                consecutive_failures = 0;
                fetched += bars.len();
                rows.extend(completed_option_rows(&contract.ticker, &bars, now)?);
            }
            Err(e) => {
                tracing::warn!("Option bars {} failed: {}", contract.ticker, e);
                failed.push(contract.ticker.clone());
                consecutive_failures += 1;
                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES {
                    return Err(AppError::Internal(format!(
                        "{} consecutive Massive failures on {} option bars, last: {}",
                        consecutive_failures, underlying, e
                    )));
                }
            }
        }
    }

    let stored = options_repo::upsert_bars(&state.db, &rows)
        .await
        .map_err(AppError::Database)?;
    tracing::info!(
        "Persisted {} option bars for {} contracts on {} ({} days, {} failed)",
        stored,
        contracts.len(),
        underlying,
        body.days,
        failed.len()
    );
    Ok(Json(json!({
        "underlying": underlying,
        "spot": spot,
        "days": body.days,
        "contracts": contracts.len(),
        "bars_fetched": fetched,
        "bars_stored": stored,
        "failed_contracts": failed,
    })))
}

/// Daily option bars share the stock rule: final once extended hours end.
fn completed_option_rows(
    ticker: &str,
    bars: &[AggBar],
    now: DateTime<Utc>,
) -> AppResult<Vec<OptionBarRow>> {
    bars.iter()
        .map(|b| OptionBarRow::from_agg(ticker, b))
        .filter(|r| {
            r.as_ref()
                .map(|r| completes_at(r.time, Granularity::D) <= now)
                .unwrap_or(true)
        })
        .collect()
}

/// Expiry window used by the sync and the bars endpoints.
fn expiry_window(today: NaiveDate, max_days: i64) -> (NaiveDate, NaiveDate) {
    (today, today + Duration::days(max_days))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn bar(t: i64) -> AggBar {
        AggBar {
            t,
            o: 1.0,
            h: 1.0,
            l: 1.0,
            c: 1.0,
            v: 1.0,
            n: None,
        }
    }

    #[test]
    fn still_forming_bars_are_dropped() {
        // 10:00 and 10:05 UTC bars; "now" is 10:07, so only the 10:00 bar is complete.
        let now = Utc.with_ymd_and_hms(2026, 10, 16, 10, 7, 0).unwrap();
        let bars = vec![
            bar(now.timestamp_millis() - 7 * 60_000),
            bar(now.timestamp_millis() - 2 * 60_000),
        ];
        let rows = completed_rows(&bars, "spy", Granularity::M5, now).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].instrument, "spy");
        assert_eq!(rows[0].granularity, Granularity::M5);
    }

    #[test]
    fn todays_daily_bar_is_final_once_extended_hours_end() {
        // 01:00 UTC Oct 16 is 21:00 New York Oct 15: after-hours are over.
        let now = Utc.with_ymd_and_hms(2026, 10, 16, 1, 0, 0).unwrap();
        let today = Utc.with_ymd_and_hms(2026, 10, 15, 4, 0, 0).unwrap();
        let bars = vec![
            bar((today - Duration::days(1)).timestamp_millis()),
            bar(today.timestamp_millis()),
        ];
        let rows = completed_rows(&bars, "SPY", Granularity::D, now).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[1].candle.time, today);
    }

    #[test]
    fn todays_daily_bar_waits_for_extended_hours() {
        // 23:30 UTC is 19:30 New York: after-hours still trading.
        let now = Utc.with_ymd_and_hms(2026, 10, 15, 23, 30, 0).unwrap();
        let today = Utc.with_ymd_and_hms(2026, 10, 15, 4, 0, 0).unwrap();
        let yesterday = today - Duration::days(1);
        let bars = vec![
            bar(yesterday.timestamp_millis()),
            bar(today.timestamp_millis()),
        ];
        let rows = completed_rows(&bars, "SPY", Granularity::D, now).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].candle.time, yesterday);
    }

    #[test]
    fn strike_band_is_symmetric_around_spot() {
        let (lo, hi) = strike_band(650.0, 0.1);
        assert!((lo - 585.0).abs() < 1e-9 && (hi - 715.0).abs() < 1e-9);
        assert_eq!(
            expiry_window(NaiveDate::from_ymd_opt(2026, 10, 22).unwrap(), 60).1,
            NaiveDate::from_ymd_opt(2026, 12, 21).unwrap()
        );
    }

    #[test]
    fn band_and_window_are_validated() {
        assert!(validate_band_and_window(0.15, 60).is_ok());
        assert!(validate_band_and_window(1.5, 60).is_err());
        assert!(validate_band_and_window(0.15, 0).is_err());
    }

    #[test]
    fn still_forming_option_bar_is_dropped() {
        // 23:30 UTC is 19:30 New York: today's daily option bar is still open.
        let now = Utc.with_ymd_and_hms(2026, 10, 22, 23, 30, 0).unwrap();
        let today = Utc.with_ymd_and_hms(2026, 10, 22, 4, 0, 0).unwrap();
        let bars = vec![
            bar((today - Duration::days(1)).timestamp_millis()),
            bar(today.timestamp_millis()),
        ];
        let rows = completed_option_rows("O:SPY261219C00650000", &bars, now).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].ticker, "O:SPY261219C00650000");
    }
}
