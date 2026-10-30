use axum::extract::State;
use axum::Json;
use chrono::{DateTime, Duration, Utc};
use serde::Deserialize;
use serde_json::{json, Value};

use super::options::ChainWindow;
use crate::brokers::massive::client::ContractFilter;
use crate::brokers::massive::models::AggBar;
use crate::brokers::stock_bar_final_at;
use crate::db::repositories::candles as candles_repo;
use crate::db::repositories::instruments as instruments_repo;
use crate::db::repositories::options::{self as options_repo, ContractRow, OptionBarRow};
use crate::engine::instrument::Instrument;
use crate::engine::options::ContractSpec;
use crate::engine::types::{Candle, CandleRow, Granularity};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

/// The free plan serves roughly two years of history; anything longer is a
/// request mistake, not a backfill.
const MAX_PERSIST_DAYS: i64 = 800;

/// A refetched daily close this far from the stored one means Massive has
/// re-adjusted the history (a split), not corrected a bar.
const ADJUSTMENT_TOLERANCE: f64 = 0.01;

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

/// The listing Massive calls `ticker`, which must be in the master: the
/// feeds store nothing for an instrument nobody has added.
async fn require_instrument(state: &AppState, ticker: &str) -> AppResult<Instrument> {
    instruments_repo::find_by_massive_ticker(&state.db, ticker)
        .await?
        .ok_or_else(|| {
            AppError::BadRequest(format!(
                "{ticker} is not in the instruments table; add it there first"
            ))
        })
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
    let instrument = require_instrument(&state, &symbol).await?;
    let now = Utc::now();
    let from = (now - Duration::days(body.days)).date_naive();
    let to = now.date_naive();

    let mut raw = massive
        .get_aggregates(&symbol, granularity, from, to)
        .await?;

    // Only bars that have fully closed: a run during the session must not
    // store a still-forming bar that the next run would see differently.
    let mut rows = completed_rows(&raw, &symbol, granularity, now)?;

    // Bars are split-adjusted as of the fetch, so after a split the short
    // nightly window comes back on the new scale while older stored bars
    // stay on the old one. Spot it in the overlap and refetch everything
    // stored for the symbol.
    let mut full_refetch = None;
    if let (Granularity::D, Some(first), Some(last)) = (granularity, rows.first(), rows.last()) {
        let stored = candles_repo::closes_between(
            &state.db,
            &symbol,
            granularity,
            first.candle.time,
            last.candle.time,
        )
        .await
        .map_err(AppError::Database)?;
        if let Some(ratio) = adjustment_ratio(&stored, &rows) {
            let oldest = candles_repo::earliest_candle_time(&state.db, &symbol, granularity)
                .await
                .map_err(AppError::Database)?
                .map_or(from, |t| t.date_naive());
            tracing::warn!(
                "Massive {} daily closes moved ×{:.4} against stored bars (split?); \
                 refetching all stored history from {}",
                symbol,
                ratio,
                oldest
            );
            raw = massive
                .get_aggregates(&symbol, granularity, oldest, to)
                .await?;
            rows = completed_rows(&raw, &symbol, granularity, now)?;
            full_refetch = Some(json!({ "from": oldest, "ratio": ratio }));
        }
    }

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
        "instrument_id": instrument.id,
        "granularity": granularity.as_str(),
        "days": body.days,
        "candles_fetched": raw.len(),
        "candles_stored": stored,
        "first": rows.first().map(|r| r.candle.time),
        "last": rows.last().map(|r| r.candle.time),
        "full_refetch": full_refetch,
    })))
}

/// Stored close ÷ refetched close at the timestamp where the two differ
/// most, when that is more than `ADJUSTMENT_TOLERANCE` (a split of 2:1
/// gives 2.0); None when every overlapping bar agrees.
fn adjustment_ratio(stored: &[(DateTime<Utc>, f64)], fetched: &[CandleRow]) -> Option<f64> {
    stored
        .iter()
        .filter_map(|(time, stored_close)| {
            let row = fetched.iter().find(|r| r.candle.time == *time)?;
            let ratio = stored_close / row.candle.mid.close;
            ratio.is_finite().then_some(ratio)
        })
        .max_by(|a, b| a.ln().abs().total_cmp(&b.ln().abs()))
        .filter(|ratio| (ratio - 1.0).abs() > ADJUSTMENT_TOLERANCE)
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
        .filter(|c| stock_bar_final_at(c.time, granularity) <= now)
        .map(|candle| CandleRow {
            instrument: symbol.to_string(),
            granularity,
            candle,
        })
        .collect())
}

// --- Options ---
//
// The history path: contracts near the money and their daily bars, one
// vendor call per contract, which the free plan's five-a-minute limit makes
// slow. The nightly chain snapshot is the Questrade path; the two-year
// history load is a separate flat-file path on a paid plan.

#[derive(Debug, Deserialize)]
pub struct SyncContracts {
    pub underlying: String,
    #[serde(flatten)]
    pub window: ChainWindow,
}

#[derive(Debug, Deserialize)]
pub struct PersistOptionBars {
    pub underlying: String,
    /// Calendar days back to (re)fetch per contract.
    #[serde(default = "default_persist_days")]
    pub days: i64,
    #[serde(flatten)]
    pub window: ChainWindow,
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

/// Fetch the contracts on `underlying` expiring within the window and
/// striking within the band, and upsert them into `option_contracts`.
pub async fn sync_option_contracts(
    State(state): State<AppState>,
    Json(body): Json<SyncContracts>,
) -> AppResult<Json<Value>> {
    let Some(massive) = state.massive.as_ref() else {
        return Err(AppError::Internal("Massive not configured".into()));
    };
    body.window.validate()?;
    let underlying = body.underlying.trim().to_uppercase();
    let instrument = require_instrument(&state, &underlying).await?;
    let spot = underlying_spot(&state, &underlying).await?;
    let now = Utc::now();
    let ((expires_from, expires_to), strikes) = body.window.bounds(now.date_naive(), spot);
    let filter = ContractFilter {
        underlying: underlying.clone(),
        expires_from,
        expires_to,
        strikes: Some(strikes),
        expired: false,
        as_of: None,
    };

    let contracts = massive.list_option_contracts(&filter).await?;
    let specs: Vec<ContractSpec> = contracts
        .iter()
        .filter_map(|c| {
            ContractSpec::try_from(c)
                .map_err(|e| tracing::warn!("Skipping Massive contract: {}", e))
                .ok()
        })
        .collect();
    let stored = options_repo::upsert_contracts(&state.db, instrument.id, &specs, now)
        .await
        .map_err(AppError::Database)?;
    tracing::info!(
        "Synced {} {} option contracts (spot {:.2}, ±{:.0}%, {} days)",
        stored.len(),
        instrument.label(),
        spot,
        body.window.strike_band_pct * 100.0,
        body.window.max_days_to_expiry
    );
    Ok(Json(json!({
        "underlying": underlying,
        "instrument_id": instrument.id,
        "spot": spot,
        "expires_from": filter.expires_from,
        "expires_to": filter.expires_to,
        "strikes": filter.strikes,
        "contracts_fetched": contracts.len(),
        "contracts_stored": stored.len(),
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
    body.window.validate()?;
    if !(1..=MAX_PERSIST_DAYS).contains(&body.days) {
        return Err(AppError::BadRequest(format!(
            "days must be in 1..={MAX_PERSIST_DAYS}, got {}",
            body.days
        )));
    }
    let underlying = body.underlying.trim().to_uppercase();
    let instrument = require_instrument(&state, &underlying).await?;
    let spot = underlying_spot(&state, &underlying).await?;
    let now = Utc::now();
    let today = now.date_naive();
    let from = today - Duration::days(body.days);
    let ((_, expires_to), strikes) = body.window.bounds(today, spot);

    // Contracts that expired inside the window still have bars to collect.
    let contracts =
        options_repo::list_contracts(&state.db, instrument.id, from, expires_to, Some(strikes))
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
                rows.extend(completed_option_rows(contract, &bars, now)?);
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
        "instrument_id": instrument.id,
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
    contract: &ContractRow,
    bars: &[AggBar],
    now: DateTime<Utc>,
) -> AppResult<Vec<OptionBarRow>> {
    bars.iter()
        .map(|b| OptionBarRow::from_agg(contract, b))
        .filter(|r| {
            r.as_ref()
                .map(|r| stock_bar_final_at(r.time, Granularity::D) <= now)
                .unwrap_or(true)
        })
        .collect()
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

    fn daily(day: u32, close: f64) -> CandleRow {
        let t = Utc.with_ymd_and_hms(2026, 10, day, 4, 0, 0).unwrap();
        let mut bar = bar(t.timestamp_millis());
        bar.c = close;
        completed_rows(&[bar], "NVDA", Granularity::D, t + Duration::days(1))
            .unwrap()
            .remove(0)
    }

    fn stored_close(day: u32, close: f64) -> (DateTime<Utc>, f64) {
        (Utc.with_ymd_and_hms(2026, 10, day, 4, 0, 0).unwrap(), close)
    }

    #[test]
    fn a_split_shows_as_the_stored_to_refetched_ratio() {
        // 2:1 split effective the 22nd: the refetch halves the 20th and 21st.
        let fetched = vec![daily(20, 100.0), daily(21, 101.0), daily(22, 102.0)];
        let stored = vec![stored_close(20, 200.0), stored_close(21, 202.0)];
        let ratio = adjustment_ratio(&stored, &fetched).unwrap();
        assert!((ratio - 2.0).abs() < 1e-9);
        // A reverse split shows below one.
        let stored = vec![stored_close(20, 10.0)];
        let ratio = adjustment_ratio(&stored, &fetched).unwrap();
        assert!((ratio - 0.1).abs() < 1e-9);
    }

    #[test]
    fn small_corrections_and_new_bars_are_not_a_split() {
        let fetched = vec![daily(20, 100.0), daily(21, 101.0)];
        // Within 1%: a vendor correction, not an adjustment.
        assert_eq!(adjustment_ratio(&[stored_close(20, 100.5)], &fetched), None);
        // No overlap (all new bars) or nothing stored.
        assert_eq!(adjustment_ratio(&[stored_close(19, 50.0)], &fetched), None);
        assert_eq!(adjustment_ratio(&[], &fetched), None);
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
    fn still_forming_option_bar_is_dropped() {
        // 23:30 UTC is 19:30 New York: today's daily option bar is still open.
        let now = Utc.with_ymd_and_hms(2026, 10, 22, 23, 30, 0).unwrap();
        let today = Utc.with_ymd_and_hms(2026, 10, 22, 4, 0, 0).unwrap();
        let bars = vec![
            bar((today - Duration::days(1)).timestamp_millis()),
            bar(today.timestamp_millis()),
        ];
        let contract = ContractRow {
            id: 1,
            ticker: "O:SPY261219C00650000".into(),
            underlying_instrument_id: crate::engine::instrument::InstrumentId(1),
            underlying: "SPY".into(),
            contract_type: "call".into(),
            expiration_date: chrono::NaiveDate::from_ymd_opt(2026, 12, 19).unwrap(),
            strike: 650.0,
            shares_per_contract: 100,
        };
        let rows = completed_option_rows(&contract, &bars, now).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].ticker, "O:SPY261219C00650000");
    }
}
