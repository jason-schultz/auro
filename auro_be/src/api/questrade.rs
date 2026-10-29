use std::collections::HashMap;

use axum::extract::{Query, State};
use axum::Json;
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::options::ChainWindow;
use crate::brokers::questrade::client::QuestradeClient;
use crate::brokers::questrade::identity;
use crate::brokers::questrade::models::{EquityCandle, OptionQuote, QuoteResult, SymbolDetail};
use crate::brokers::questrade::options::{select_contracts, SelectedContract};
use crate::db::repositories::candles as candles_repo;
use crate::db::repositories::instruments as instruments_repo;
use crate::db::repositories::options::{
    self as options_repo, ContractRow, OptionQuoteRow, StoredContract,
};
use crate::engine::instrument::Instrument;
use crate::engine::options::ContractSpec;
use crate::engine::types::{Candle, CandleRow, Granularity};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

pub async fn status(State(state): State<AppState>) -> AppResult<Json<Value>> {
    let Some(qt) = state.questrade.as_ref() else {
        return Ok(Json(json!({ "connected": false, "accounts": [] })));
    };

    let mut client = qt.lock().await;
    match client.get_accounts().await {
        Ok(accounts) => Ok(Json(json!({ "connected": true, "accounts": accounts }))),
        Err(e) => Ok(Json(
            json!({ "connected": false, "accounts": [], "error": e.to_string() }),
        )),
    }
}

#[derive(Debug, Deserialize)]
pub struct CandlesQuery {
    pub symbol: String,
    pub start: Option<String>,
    pub end: Option<String>,
    pub interval: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CandlesResponse {
    pub symbol: String,
    pub symbol_id: i64,
    pub interval: String,
    pub start: String,
    pub end: String,
    pub candles: Vec<EquityCandle>,
}

pub async fn get_candles(
    State(state): State<AppState>,
    Query(params): Query<CandlesQuery>,
) -> AppResult<Json<CandlesResponse>> {
    let Some(qt) = state.questrade.as_ref() else {
        return Err(AppError::Internal("Questrade not configured".into()));
    };

    let year = Utc::now().format("%Y").to_string();
    let start = params.start.unwrap_or_else(|| format!("{}-01-01", year));
    let end = params
        .end
        .unwrap_or_else(|| Utc::now().format("%Y-%m-%d").to_string());
    let interval = params.interval.unwrap_or_else(|| "OneDay".to_string());

    let mut client = qt.lock().await;
    let symbol_id = client.search_symbol(&params.symbol).await.map_err(|e| {
        tracing::error!("Questrade symbol search failed: {}", e);
        e
    })?;
    let candles = client
        .get_candles(symbol_id, &start, &end, &interval)
        .await
        .map_err(|e| {
            tracing::error!(
                "Questrade get_candles failed (symbolId={}): {}",
                symbol_id,
                e
            );
            e
        })?;

    Ok(Json(CandlesResponse {
        symbol: params.symbol.to_uppercase(),
        symbol_id,
        interval,
        start,
        end,
        candles,
    }))
}

/// Upper bound on symbols per batch request, keeping one call's symbol
/// searches well inside Questrade's per-second market-data rate limit.
const MAX_BATCH_SYMBOLS: usize = 50;

#[derive(Debug, Deserialize)]
pub struct SymbolsQuery {
    /// Comma-separated tickers, e.g. "HUT.TO,HIVE.TO".
    pub symbols: String,
}

/// Tickers resolved to Questrade symbol IDs, plus the ones that failed.
/// `requested` is kept alongside each ID because `search_symbol` falls back to
/// the first search hit when there's no exact match — callers compare it with
/// the `symbol` Questrade returns.
struct Resolved {
    ids: Vec<(String, i64)>,
    unresolved: Vec<String>,
}

async fn resolve_symbols(client: &mut QuestradeClient, symbols: &str) -> AppResult<Resolved> {
    let requested: Vec<String> = symbols
        .split(',')
        .map(|s| s.trim().to_uppercase())
        .filter(|s| !s.is_empty())
        .collect();
    if requested.is_empty() || requested.len() > MAX_BATCH_SYMBOLS {
        return Err(AppError::BadRequest(format!(
            "symbols must list 1..={MAX_BATCH_SYMBOLS} tickers, got {}",
            requested.len()
        )));
    }

    let mut resolved = Resolved {
        ids: Vec::new(),
        unresolved: Vec::new(),
    };
    for symbol in requested {
        match client.search_symbol(&symbol).await {
            Ok(id) => resolved.ids.push((symbol, id)),
            Err(e) => {
                tracing::warn!("Questrade could not resolve {}: {}", symbol, e);
                resolved.unresolved.push(symbol);
            }
        }
    }
    Ok(resolved)
}

fn ids(resolved: &Resolved) -> Vec<i64> {
    resolved.ids.iter().map(|(_, id)| *id).collect()
}

fn requested_for(resolved: &Resolved, symbol_id: i64) -> Option<String> {
    resolved
        .ids
        .iter()
        .find(|(_, id)| *id == symbol_id)
        .map(|(requested, _)| requested.clone())
}

#[derive(Debug, Serialize)]
pub struct QuoteView {
    pub requested: Option<String>,
    #[serde(flatten)]
    pub quote: QuoteResult,
    /// (ask − bid) / mid, in percent; None when either side is missing.
    pub spread_pct: Option<f64>,
}

#[derive(Debug, Serialize)]
pub struct QuotesView {
    pub quotes: Vec<QuoteView>,
    pub unresolved: Vec<String>,
}

fn spread_pct(bid: Option<f64>, ask: Option<f64>) -> Option<f64> {
    let (bid, ask) = (bid?, ask?);
    let mid = (bid + ask) / 2.0;
    (bid > 0.0 && ask >= bid).then(|| (ask - bid) / mid * 100.0)
}

pub async fn get_quotes(
    State(state): State<AppState>,
    Query(params): Query<SymbolsQuery>,
) -> AppResult<Json<QuotesView>> {
    let Some(qt) = state.questrade.as_ref() else {
        return Err(AppError::Internal("Questrade not configured".into()));
    };

    let mut client = qt.lock().await;
    let resolved = resolve_symbols(&mut client, &params.symbols).await?;
    let quotes = client.get_quotes(&ids(&resolved)).await?;
    drop(client);

    let quotes = quotes
        .into_iter()
        .map(|quote| QuoteView {
            requested: requested_for(&resolved, quote.symbol_id),
            spread_pct: spread_pct(quote.bid_price, quote.ask_price),
            quote,
        })
        .collect();
    Ok(Json(QuotesView {
        quotes,
        unresolved: resolved.unresolved,
    }))
}

#[derive(Debug, Serialize)]
pub struct SymbolView {
    pub requested: Option<String>,
    #[serde(flatten)]
    pub detail: SymbolDetail,
}

#[derive(Debug, Serialize)]
pub struct SymbolsView {
    pub symbols: Vec<SymbolView>,
    pub unresolved: Vec<String>,
}

pub async fn get_symbols(
    State(state): State<AppState>,
    Query(params): Query<SymbolsQuery>,
) -> AppResult<Json<SymbolsView>> {
    let Some(qt) = state.questrade.as_ref() else {
        return Err(AppError::Internal("Questrade not configured".into()));
    };

    let mut client = qt.lock().await;
    let resolved = resolve_symbols(&mut client, &params.symbols).await?;
    let details = client.get_symbols(&ids(&resolved)).await?;
    drop(client);

    let symbols = details
        .into_iter()
        .map(|detail| SymbolView {
            requested: requested_for(&resolved, detail.symbol_id),
            detail,
        })
        .collect();
    Ok(Json(SymbolsView {
        symbols,
        unresolved: resolved.unresolved,
    }))
}

/// Longest window one persist call may re-fetch; Questrade's intraday
/// retention is ~3 months, so anything older returns nothing anyway.
const MAX_PERSIST_DAYS: i64 = 120;

fn default_persist_days() -> i64 {
    5
}

#[derive(Debug, Deserialize)]
pub struct PersistCandles {
    pub symbol: String,
    /// Our granularity name ("M1", "M5", ...).
    pub granularity: String,
    /// Calendar days back from today to (re)fetch. Re-fetching overlaps is
    /// harmless — the upsert overwrites identical rows — so a scheduler can
    /// pull a few days each run and heal any missed day.
    #[serde(default = "default_persist_days")]
    pub days: i64,
}

/// The listing Questrade calls `symbol`, which must be in the master: the
/// feeds store nothing for an instrument nobody has added.
async fn require_instrument(state: &AppState, symbol: &str) -> AppResult<Instrument> {
    instruments_repo::find_by_questrade_symbol(&state.db, symbol)
        .await?
        .ok_or_else(|| {
            AppError::BadRequest(format!(
                "{symbol} is not in the instruments table; add it there first"
            ))
        })
}

/// Fetch a symbol's Questrade bars and store the completed ones in the shared
/// `candles` table under the Questrade ticker (e.g. "HUT.TO"), building the
/// history Questrade itself only retains for ~3 months.
pub async fn persist_candles(
    State(state): State<AppState>,
    Json(body): Json<PersistCandles>,
) -> AppResult<Json<Value>> {
    let Some(qt) = state.questrade.as_ref() else {
        return Err(AppError::Internal("Questrade not configured".into()));
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
    let start = (now - Duration::days(body.days))
        .format("%Y-%m-%d")
        .to_string();
    let end = now.format("%Y-%m-%d").to_string();

    let instrument = require_instrument(&state, &symbol).await?;
    let mut client = qt.lock().await;
    let symbol_id = identity::resolve_symbol_id(&mut client, &state.db, &instrument).await?;
    let raw = client
        .get_candles(
            symbol_id,
            &start,
            &end,
            QuestradeClient::interval_for(granularity),
        )
        .await?;
    drop(client);

    // Only bars that have fully closed: a run during the session must not
    // store a still-forming bar that the next run would see differently.
    let bar = Duration::minutes(granularity.minutes());
    let rows: Vec<CandleRow> = raw
        .iter()
        .map(Candle::try_from)
        .collect::<AppResult<Vec<_>>>()?
        .into_iter()
        .filter(|c| c.time + bar <= now)
        .map(|candle| CandleRow {
            instrument: symbol.clone(),
            granularity,
            candle,
        })
        .collect();

    let stored = candles_repo::upsert_candles(&state.db, &rows)
        .await
        .map_err(AppError::Database)?;
    tracing::info!(
        "Persisted {} Questrade {} {} candles ({} days)",
        stored,
        symbol,
        granularity,
        body.days
    );

    Ok(Json(json!({
        "symbol": symbol,
        "instrument_id": instrument.id,
        "symbol_id": symbol_id,
        "granularity": granularity.as_str(),
        "days": body.days,
        "candles_stored": stored,
        "first": rows.first().map(|r| r.candle.time),
        "last": rows.last().map(|r| r.candle.time),
    })))
}

// --- Options ---
//
// The live chain path: Questrade lists the chain and quotes it with the
// exchange greeks, free and inside the rate limit, so the nightly snapshot
// comes from here. History stays with Massive (api/massive.rs).

#[derive(Debug, Deserialize)]
pub struct SnapshotChain {
    pub underlying: String,
    #[serde(flatten)]
    pub window: ChainWindow,
}

/// Which vendor's quote a row holds, and from which capture: a whole-chain
/// snapshot, or the held contracts quoted during the session. Opus reads
/// "the latest chain" from chain snapshots only, so a few held-contract
/// quotes never stand in for the chain (`Opus.Options.latest_quotes/1`).
/// `option_quotes.source` is varchar(16).
const CHAIN_SOURCE: &str = "questrade";
const HELD_SOURCE: &str = "questrade_legs";

/// The underlying's price for the strike band and the stored `spot`: the
/// last trade, or the bid/ask mid when nothing has traded.
fn quote_price(q: &QuoteResult) -> Option<f64> {
    q.last_trade_price.filter(|p| *p > 0.0).or_else(|| {
        let (bid, ask) = (q.bid_price?, q.ask_price?);
        (bid > 0.0 && ask >= bid).then(|| (bid + ask) / 2.0)
    })
}

/// Capture the near-the-money chain on `underlying` as Questrade quotes it
/// now: the contracts into `option_contracts`, one `option_quotes` row per
/// contract with the exchange greeks. Opus runs it nightly after the close,
/// when the quotes are the day's closing values and the data delay does
/// not matter.
pub async fn snapshot_option_chain(
    State(state): State<AppState>,
    Json(body): Json<SnapshotChain>,
) -> AppResult<Json<Value>> {
    let Some(qt) = state.questrade.as_ref() else {
        return Err(AppError::Internal("Questrade not configured".into()));
    };
    body.window.validate()?;
    let underlying = body.underlying.trim().to_uppercase();
    let instrument = require_instrument(&state, &underlying).await?;
    let captured_at = Utc::now();

    let mut client = qt.lock().await;
    let symbol_id = identity::resolve_symbol_id(&mut client, &state.db, &instrument).await?;
    let spot = client
        .get_quotes(&[symbol_id])
        .await?
        .first()
        .and_then(quote_price)
        .ok_or_else(|| {
            AppError::Internal(format!(
                "Questrade has no price for {underlying} (symbolId={symbol_id})"
            ))
        })?;
    let chain = client.get_option_chain(symbol_id).await?;
    let (expiries, strikes) = body.window.bounds(captured_at.date_naive(), spot);
    let selected = select_contracts(&chain, &instrument.symbol, expiries, strikes)?;
    let option_ids: Vec<i64> = selected.iter().map(|c| c.option_id).collect();
    let quotes = client.get_option_quotes(&option_ids).await?;
    drop(client);

    let specs: Vec<ContractSpec> = selected.iter().map(|c| c.spec.clone()).collect();
    let stored = options_repo::upsert_contracts(&state.db, instrument.id, &specs, captured_at)
        .await
        .map_err(AppError::Database)?;
    let rows = quote_rows(&selected, &stored, &quotes, spot, captured_at, CHAIN_SOURCE);
    let quotes_stored = options_repo::insert_quotes(&state.db, &rows)
        .await
        .map_err(AppError::Database)?;
    let max_delay = rows.iter().filter_map(|r| r.delay_seconds).max();
    tracing::info!(
        "Snapshot {} option chain: {} contracts, {} quotes (spot {:.2}, ±{:.0}%, {} days, delay ≤ {:?}s)",
        instrument.label(),
        stored.len(),
        quotes_stored,
        spot,
        body.window.strike_band_pct * 100.0,
        body.window.max_days_to_expiry,
        max_delay
    );

    Ok(Json(json!({
        "underlying": underlying,
        "instrument_id": instrument.id,
        "symbol_id": symbol_id,
        "spot": spot,
        "captured_at": captured_at,
        "expires_from": expiries.0,
        "expires_to": expiries.1,
        "strikes": strikes,
        "chain_expiries": chain.len(),
        "contracts_selected": selected.len(),
        "contracts_stored": stored.len(),
        "quotes_fetched": quotes.len(),
        "quotes_stored": quotes_stored,
        "max_delay_seconds": max_delay,
    })))
}

#[derive(Debug, Deserialize)]
pub struct QuoteContracts {
    pub underlying: String,
    /// `option_contracts` ids, all on `underlying`.
    pub contract_ids: Vec<i64>,
}

/// Quote only the stored contracts asked for (the paper books' open legs)
/// and store the quotes in `option_quotes`, without touching the rest of
/// the chain: one underlying quote, one chain listing and one option
/// quotes call. A contract no longer in Questrade's chain is reported in
/// `missing`, not an error.
pub async fn quote_option_contracts(
    State(state): State<AppState>,
    Json(body): Json<QuoteContracts>,
) -> AppResult<Json<Value>> {
    let Some(qt) = state.questrade.as_ref() else {
        return Err(AppError::Internal("Questrade not configured".into()));
    };
    let underlying = body.underlying.trim().to_uppercase();
    let instrument = require_instrument(&state, &underlying).await?;
    let contracts = options_repo::contracts_by_ids(&state.db, instrument.id, &body.contract_ids)
        .await
        .map_err(AppError::Database)?;
    let (Some(first), Some(last)) = (contracts.first(), contracts.last()) else {
        return Ok(Json(
            json!({ "underlying": underlying, "quotes_stored": 0, "missing": body.contract_ids }),
        ));
    };
    let expiries = (first.expiration_date, last.expiration_date);
    let strikes = contracts.iter().fold((f64::MAX, f64::MIN), |(lo, hi), c| {
        (lo.min(c.strike), hi.max(c.strike))
    });
    let captured_at = Utc::now();

    let mut client = qt.lock().await;
    let symbol_id = identity::resolve_symbol_id(&mut client, &state.db, &instrument).await?;
    let spot = client
        .get_quotes(&[symbol_id])
        .await?
        .first()
        .and_then(quote_price)
        .ok_or_else(|| {
            AppError::Internal(format!(
                "Questrade has no price for {underlying} (symbolId={symbol_id})"
            ))
        })?;
    let chain = client.get_option_chain(symbol_id).await?;
    let in_window = select_contracts(&chain, &instrument.symbol, expiries, strikes)?;
    let (selected, stored) = match_contracts(&in_window, &contracts);
    let option_ids: Vec<i64> = selected.iter().map(|c| c.option_id).collect();
    let quotes = if option_ids.is_empty() {
        Vec::new()
    } else {
        client.get_option_quotes(&option_ids).await?
    };
    drop(client);

    let rows = quote_rows(&selected, &stored, &quotes, spot, captured_at, HELD_SOURCE);
    let quotes_stored = options_repo::insert_quotes(&state.db, &rows)
        .await
        .map_err(AppError::Database)?;
    let quoted: Vec<i64> = rows.iter().map(|r| r.contract_id).collect();
    let missing: Vec<i64> = body
        .contract_ids
        .iter()
        .copied()
        .filter(|id| !quoted.contains(id))
        .collect();

    Ok(Json(json!({
        "underlying": underlying,
        "spot": spot,
        "captured_at": captured_at,
        "quotes_stored": quotes_stored,
        "missing": missing,
    })))
}

/// The chain contracts that are the stored ones, matched on expiry, strike
/// and kind, each paired with its stored id under the chain's ticker (the
/// label `quote_rows` joins on).
fn match_contracts(
    chain: &[SelectedContract],
    stored: &[ContractRow],
) -> (Vec<SelectedContract>, Vec<StoredContract>) {
    chain
        .iter()
        .filter_map(|c| {
            let row = stored.iter().find(|r| {
                r.expiration_date == c.spec.expiration
                    && r.strike == c.spec.strike
                    && r.contract_type == c.spec.kind.as_str()
            })?;
            let label = StoredContract {
                id: row.id,
                ticker: c.spec.ticker.clone(),
            };
            Some((c.clone(), label))
        })
        .unzip()
}

/// Join the quotes back to the contracts they were requested for, by the
/// ids the upsert handed back. A contract Questrade returned no quote for
/// is left out, not stored empty.
fn quote_rows(
    selected: &[SelectedContract],
    stored: &[StoredContract],
    quotes: &[OptionQuote],
    spot: f64,
    captured_at: DateTime<Utc>,
    source: &str,
) -> Vec<OptionQuoteRow> {
    let tickers: HashMap<i64, &str> = selected
        .iter()
        .map(|c| (c.option_id, c.spec.ticker.as_str()))
        .collect();
    let ids: HashMap<&str, i64> = stored.iter().map(|c| (c.ticker.as_str(), c.id)).collect();
    quotes
        .iter()
        .filter_map(|q| {
            let ticker = tickers.get(&q.symbol_id)?;
            let contract_id = *ids.get(ticker)?;
            Some(OptionQuoteRow {
                contract_id,
                ticker: ticker.to_string(),
                captured_at,
                source: source.to_string(),
                spot,
                bid: q.bid_price,
                ask: q.ask_price,
                last: q.last_trade_price,
                bid_size: count(q.bid_size),
                ask_size: count(q.ask_size),
                volume: count(q.volume),
                open_interest: count(q.open_interest),
                volatility: q.volatility,
                delta: q.delta,
                gamma: q.gamma,
                theta: q.theta,
                vega: q.vega,
                rho: q.rho,
                delay_seconds: q.delay.map(|d| d.clamp(0, i64::from(i32::MAX)) as i32),
            })
        })
        .collect()
}

/// Vendor counts arrive as numbers; the columns are integers.
fn count(v: Option<f64>) -> Option<i32> {
    v.map(|v| v.round().clamp(0.0, f64::from(i32::MAX)) as i32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::options::OptionKind;
    use chrono::NaiveDate;

    #[test]
    fn equity_candle_converts_offset_time_to_utc() {
        let c = Candle::try_from(&EquityCandle {
            time: "2026-07-20T09:30:00.000000-04:00".into(),
            open: 10.0,
            high: 11.0,
            low: 9.5,
            close: 10.5,
            volume: 1234.6,
            vwap: Some(10.2),
        })
        .unwrap();
        assert_eq!(c.time.to_rfc3339(), "2026-07-20T13:30:00+00:00");
        assert_eq!(c.volume, 1235);
        assert_eq!(c.mid.close, 10.5);
        assert!(c.bid.is_none() && c.ask.is_none());
    }

    #[test]
    fn spread_pct_is_relative_to_mid() {
        let s = spread_pct(Some(9.99), Some(10.01)).unwrap();
        assert!((s - 0.2).abs() < 1e-9);
    }

    #[test]
    fn spread_pct_none_when_a_side_is_missing_or_crossed() {
        assert_eq!(spread_pct(None, Some(10.0)), None);
        assert_eq!(spread_pct(Some(0.0), Some(10.0)), None);
        assert_eq!(spread_pct(Some(10.02), Some(10.0)), None);
    }

    fn quote(last: Option<f64>, bid: Option<f64>, ask: Option<f64>) -> QuoteResult {
        QuoteResult {
            symbol: "SPY".into(),
            symbol_id: 1,
            last_trade_price: last,
            last_trade_time: None,
            bid_price: bid,
            bid_size: None,
            ask_price: ask,
            ask_size: None,
            open_price: None,
            high_price: None,
            low_price: None,
            volume: None,
            delay: None,
            is_halted: None,
        }
    }

    #[test]
    fn spot_is_the_last_trade_then_the_mid() {
        assert_eq!(
            quote_price(&quote(Some(769.05), Some(768.0), Some(770.0))),
            Some(769.05)
        );
        assert_eq!(
            quote_price(&quote(Some(0.0), Some(768.0), Some(770.0))),
            Some(769.0)
        );
        assert_eq!(quote_price(&quote(None, None, Some(770.0))), None);
    }

    fn option_quote(symbol_id: i64) -> OptionQuote {
        OptionQuote {
            symbol: "SPY20Nov26P640.00".into(),
            symbol_id,
            underlying: Some("SPY".into()),
            underlying_id: Some(1),
            bid_price: Some(6.3),
            bid_size: Some(12.0),
            ask_price: Some(6.5),
            ask_size: Some(40.0),
            last_trade_price: Some(6.4),
            last_trade_time: None,
            volume: Some(1500.6),
            open_interest: Some(23_000.0),
            volatility: Some(40.45),
            delta: Some(-0.14),
            gamma: Some(0.004),
            theta: Some(-0.21),
            vega: Some(0.55),
            rho: Some(-0.08),
            delay: Some(900),
            is_halted: Some(false),
        }
    }

    fn chain_contract(kind: OptionKind, strike: f64, option_id: i64) -> SelectedContract {
        SelectedContract {
            spec: ContractSpec {
                ticker: format!("O:SPY261120{}{strike}", kind.as_str()),
                underlying: "SPY".into(),
                kind,
                expiration: NaiveDate::from_ymd_opt(2026, 11, 20).unwrap(),
                strike,
                shares_per_contract: 100,
                exercise_style: None,
                primary_exchange: None,
            },
            option_id,
        }
    }

    #[test]
    fn match_contracts_keeps_only_the_stored_ones_with_their_ids() {
        let chain = vec![
            chain_contract(OptionKind::Put, 640.0, 41),
            chain_contract(OptionKind::Call, 640.0, 42),
            chain_contract(OptionKind::Put, 650.0, 43),
        ];
        let stored = vec![ContractRow {
            id: 7,
            ticker: "SPY 640 P".into(),
            underlying_instrument_id: crate::engine::instrument::InstrumentId(1),
            underlying: "SPY".into(),
            contract_type: "put".into(),
            expiration_date: NaiveDate::from_ymd_opt(2026, 11, 20).unwrap(),
            strike: 640.0,
            shares_per_contract: 100,
        }];
        let (selected, labels) = match_contracts(&chain, &stored);
        assert_eq!(
            selected.iter().map(|c| c.option_id).collect::<Vec<_>>(),
            vec![41]
        );
        assert_eq!(labels.len(), 1);
        assert_eq!(
            (labels[0].id, labels[0].ticker.as_str()),
            (7, "O:SPY261120put640")
        );
    }

    #[test]
    fn quote_rows_join_on_the_option_id_and_drop_strangers() {
        let selected = vec![SelectedContract {
            spec: ContractSpec {
                ticker: "O:SPY261120P00640000".into(),
                underlying: "SPY".into(),
                kind: OptionKind::Put,
                expiration: NaiveDate::from_ymd_opt(2026, 11, 20).unwrap(),
                strike: 640.0,
                shares_per_contract: 100,
                exercise_style: None,
                primary_exchange: None,
            },
            option_id: 42,
        }];
        let stored = vec![StoredContract {
            id: 7,
            ticker: "O:SPY261120P00640000".into(),
        }];
        let captured_at = Utc::now();
        let rows = quote_rows(
            &selected,
            &stored,
            &[option_quote(42), option_quote(43)],
            769.05,
            captured_at,
            CHAIN_SOURCE,
        );
        assert_eq!(rows.len(), 1);
        let row = &rows[0];
        assert_eq!(
            (row.contract_id, row.ticker.as_str()),
            (7, "O:SPY261120P00640000")
        );
        assert_eq!(row.source, "questrade");
        assert_eq!(row.spot, 769.05);
        assert_eq!((row.volume, row.open_interest), (Some(1501), Some(23_000)));
        assert_eq!(row.delay_seconds, Some(900));
        assert_eq!(row.volatility, Some(40.45));
    }
}
