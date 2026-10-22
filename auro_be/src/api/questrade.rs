use axum::extract::{Query, State};
use axum::Json;
use chrono::{Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::brokers::questrade::client::QuestradeClient;
use crate::brokers::questrade::models::{EquityCandle, QuoteResult, SymbolDetail};
use crate::db::repositories::candles as candles_repo;
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

    let mut client = qt.lock().await;
    let symbol_id = client.search_symbol(&symbol).await?;
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
        "symbol_id": symbol_id,
        "granularity": granularity.as_str(),
        "days": body.days,
        "candles_stored": stored,
        "first": rows.first().map(|r| r.candle.time),
        "last": rows.last().map(|r| r.candle.time),
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
