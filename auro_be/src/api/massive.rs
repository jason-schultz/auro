use axum::extract::State;
use axum::Json;
use chrono::{DateTime, Duration, Utc};
use chrono_tz::America::New_York;
use serde::Deserialize;
use serde_json::{json, Value};

use super::options::ChainWindow;
use crate::brokers::adjusted;
use crate::brokers::massive::client::{ContractFilter, MassiveClient};
use crate::brokers::massive::models::{AggBar, Dividend, Split};
use crate::brokers::stock_bar_final_at;
use crate::db::repositories::candles as candles_repo;
use crate::db::repositories::dividends as dividends_repo;
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

#[derive(Debug, Deserialize)]
pub struct PersistDividends {
    pub symbol: String,
}

/// Fetch every cash dividend `symbol` has paid from Massive and store them,
/// stamping the instrument as checked (none found: it pays none). The tests
/// of shares held at a broker with no overnight cost add them back to long
/// holds; the bars alone leave them out.
pub async fn persist_dividends(
    State(state): State<AppState>,
    Json(body): Json<PersistDividends>,
) -> AppResult<Json<Value>> {
    let Some(massive) = state.connections.massive() else {
        return Err(AppError::Internal("Massive not configured".into()));
    };
    let symbol = body.symbol.trim().to_uppercase();
    let instrument = require_instrument(&state, &symbol).await?;
    Ok(Json(
        load_dividends(&state, &massive, &instrument, &symbol).await?,
    ))
}

/// Store `symbol`'s dividends on the scale of its stored bars. Massive
/// gives each payment per share as paid, while the bars are split-adjusted
/// to today: a payment before a 2:1 split is halved to match. A payment the
/// bars already price in is left out (see `priced_in`).
async fn load_dividends(
    state: &AppState,
    massive: &MassiveClient,
    instrument: &Instrument,
    symbol: &str,
) -> AppResult<Value> {
    let splits = massive.list_splits(symbol).await?;
    let paid = on_todays_shares(massive.list_dividends(symbol).await?, &splits);
    let bars = candles_repo::load_candles(&state.db, symbol, Granularity::D)
        .await
        .map_err(AppError::Database)?;
    let (priced, kept): (Vec<Dividend>, Vec<Dividend>) =
        paid.into_iter().partition(|d| priced_in(d, &bars));
    let stored = dividends_repo::store(&state.db, instrument.id, &kept)
        .await
        .map_err(AppError::Database)?;
    tracing::info!(
        "Stored {stored} Massive dividends for {symbol} ({} splits, {} priced in)",
        splits.len(),
        priced.len()
    );
    Ok(json!({
        "symbol": symbol,
        "dividends": kept.len(),
        "first": kept.first().map(|d| d.ex_dividend_date),
        "last": kept.last().map(|d| d.ex_dividend_date),
        "splits": splits.iter().map(|s| json!({
            "date": s.execution_date, "from": s.split_from, "to": s.split_to,
        })).collect::<Vec<_>>(),
        "priced_in": priced.iter().map(|d| json!({
            "ex_date": d.ex_dividend_date, "cash": d.cash_amount,
        })).collect::<Vec<_>>(),
    }))
}

/// `paid` per share held today: each payment before a split scaled by it
/// (× 1/2 before a 2:1 split), as split-adjusted bars are.
fn on_todays_shares(paid: Vec<Dividend>, splits: &[Split]) -> Vec<Dividend> {
    paid.into_iter()
        .map(|d| {
            let factor: f64 = splits
                .iter()
                .filter(|s| s.execution_date > d.ex_dividend_date && s.split_to > 0.0)
                .map(|s| s.split_from / s.split_to)
                .product();
            Dividend {
                cash_amount: d.cash_amount * factor,
                ..d
            }
        })
        .collect()
}

/// A payment over this share of the price is checked against the bars.
const BIG_PAYMENT: f64 = 0.05;

/// Whether the bars already price `d` in: a big payment (over
/// `BIG_PAYMENT` of the close before) whose ex-date shows under half of it
/// as a drop. Vendors adjust older prices for a spin-off paid as shares
/// (XLF's 2016 XLRE payment, listed as $4.44 cash, is folded into
/// Questrade's XLF bars); paying it too would count it twice. Without the
/// bars around the ex-date, it is kept.
fn priced_in(d: &Dividend, bars: &[Candle]) -> bool {
    let day = |c: &Candle| c.time.with_timezone(&New_York).date_naive();
    let Some(at) = bars.iter().position(|c| day(c) >= d.ex_dividend_date) else {
        return false;
    };
    let (Some(before), Some(ex)) = (at.checked_sub(1).map(|i| &bars[i]), bars.get(at)) else {
        return false;
    };
    let prev = before.mid.close;
    if day(ex) != d.ex_dividend_date || prev <= 0.0 {
        return false;
    }
    let share = d.cash_amount / prev;
    let drop = 1.0 - ex.mid.open / prev;
    share > BIG_PAYMENT && drop < share / 2.0
}

/// Fetch `days` of `symbol` bars from Massive and upsert the completed ones
/// into `candles`. Same contract as the Questrade persist endpoint; this is
/// the US-equity source, Questrade stays the Canadian one.
pub async fn persist_candles(
    State(state): State<AppState>,
    Json(body): Json<PersistCandles>,
) -> AppResult<Json<Value>> {
    let Some(massive) = state.connections.massive() else {
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

    let raw = massive
        .get_aggregates(&symbol, granularity, from, to)
        .await?;

    // Only bars that have fully closed: a run during the session must not
    // store a still-forming bar that the next run would see differently.
    let rows = completed_rows(&raw, &symbol, granularity, now)?;

    // Bars come split-adjusted as of the fetch: after a split, older
    // stored history is put on the new scale, and a fund's dividends
    // (already loaded) are reloaded to match.
    let rescaled = adjusted::match_stored_scale(&state.db, &rows)
        .await
        .map_err(AppError::Database)?;
    if rescaled.is_some()
        && dividends_repo::checked(&state.db, instrument.id)
            .await
            .map_err(AppError::Database)?
    {
        load_dividends(&state, &massive, &instrument, &symbol).await?;
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
        "rescaled": rescaled,
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
    let Some(massive) = state.connections.massive() else {
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
    let Some(massive) = state.connections.massive() else {
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
    use chrono::{NaiveDate, TimeZone};

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

    fn paid(y: i32, m: u32, d: u32, cash: f64) -> Dividend {
        Dividend {
            ex_dividend_date: NaiveDate::from_ymd_opt(y, m, d).unwrap(),
            pay_date: None,
            cash_amount: cash,
            frequency: Some(4),
        }
    }

    fn split(y: i32, m: u32, d: u32, from: f64, to: f64) -> Split {
        Split {
            execution_date: NaiveDate::from_ymd_opt(y, m, d).unwrap(),
            split_from: from,
            split_to: to,
        }
    }

    #[test]
    fn payments_before_a_split_are_scaled_to_todays_shares() {
        // EEM: 3:1 in 2005 and again in 2008.
        let splits = [split(2005, 6, 9, 1.0, 3.0), split(2008, 7, 24, 1.0, 3.0)];
        let scaled = on_todays_shares(
            vec![
                paid(2004, 12, 20, 9.0),
                paid(2007, 12, 24, 1.95),
                paid(2008, 12, 22, 0.5),
            ],
            &splits,
        );
        let cash: Vec<f64> = scaled.iter().map(|d| d.cash_amount).collect();
        assert!((cash[0] - 1.0).abs() < 1e-12);
        assert!((cash[1] - 0.65).abs() < 1e-12);
        assert!((cash[2] - 0.5).abs() < 1e-12);
        // A reverse split (8 → 1) scales the other way.
        let reverse =
            on_todays_shares(vec![paid(2019, 1, 2, 0.1)], &[split(2020, 4, 28, 8.0, 1.0)]);
        assert!((reverse[0].cash_amount - 0.8).abs() < 1e-12);
    }

    fn day_bar(d: u32, open: f64, close: f64) -> Candle {
        // Midnight New York, as daily stock bars are stamped.
        Candle::from_trade_bar(
            Utc.with_ymd_and_hms(2016, 9, d, 4, 0, 0).unwrap(),
            crate::engine::types::OHLC {
                open,
                high: open.max(close),
                low: open.min(close),
                close,
            },
            0.0,
        )
    }

    #[test]
    fn a_big_payment_the_bars_already_price_in_is_left_out() {
        // XLF 2016: $4.44 "cash" on a $19.18 close, and no drop on the day.
        let bars = [day_bar(16, 19.28, 19.18), day_bar(19, 19.35, 19.31)];
        assert!(priced_in(&paid(2016, 9, 19, 4.44), &bars));
        // The same payment with the drop showing is a real payment.
        let dropped = [day_bar(16, 19.28, 19.18), day_bar(19, 14.80, 14.9)];
        assert!(!priced_in(&paid(2016, 9, 19, 4.44), &dropped));
        // Ordinary payments are never second-guessed, nor any without bars.
        assert!(!priced_in(&paid(2016, 9, 19, 0.1), &bars));
        assert!(!priced_in(&paid(2016, 9, 20, 4.44), &bars));
        assert!(!priced_in(&paid(2016, 9, 19, 4.44), &[]));
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
