//! `POST /api/share-alerts/evaluate`: what each share-alert assignment says
//! today (`engine::share_alerts`), on its stored daily bars plus the day so
//! far from Questrade. Opus calls it 15 minutes before the close and sends
//! the alerts; nothing here places an order.

use std::collections::HashMap;

use axum::extract::State;
use axum::Json;
use chrono::{DateTime, NaiveDate, Utc};
use chrono_tz::America::New_York;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::brokers::questrade::identity;
use crate::brokers::questrade::models::QuoteResult;
use crate::brokers::stock_day_open;
use crate::db::repositories::candles as candles_repo;
use crate::db::repositories::live_strategies::{self as live_repo, ShareAlertAssignment};
use crate::engine::pipeline::long_only;
use crate::engine::share_alerts::{decide, today_bar, Decision, Held};
use crate::engine::strategy::Strategy;
use crate::engine::types::{Candle, Granularity};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct EvaluateRequest {
    pub assignments: Vec<AssignmentRequest>,
}

/// One assignment and, when the person holds shares logged from its
/// alerts, the day they bought and the stop set then.
#[derive(Debug, Deserialize)]
pub struct AssignmentRequest {
    pub id: Uuid,
    pub held: Option<HeldRequest>,
}

#[derive(Debug, Deserialize)]
pub struct HeldRequest {
    pub entry_day: NaiveDate,
    pub stop_price: f64,
}

#[derive(Debug, Serialize)]
pub struct AssignmentDecision {
    pub id: Uuid,
    pub instrument: String,
    #[serde(flatten)]
    pub decision: Decision,
    /// Seconds Questrade delayed the quote (0: real time).
    pub quote_delay: Option<i64>,
}

pub async fn evaluate(
    State(state): State<AppState>,
    Json(request): Json<EvaluateRequest>,
) -> AppResult<Json<Vec<AssignmentDecision>>> {
    let ids: Vec<Uuid> = request.assignments.iter().map(|a| a.id).collect();
    let assignments = live_repo::share_alert_assignments(&state.db, &ids).await?;
    let held: HashMap<Uuid, Held> = request
        .assignments
        .iter()
        .filter_map(|a| {
            a.held.as_ref().map(|h| {
                (
                    a.id,
                    Held {
                        entry_day: h.entry_day,
                        stop_price: h.stop_price,
                    },
                )
            })
        })
        .collect();

    let quotes = quotes_for(&state, &assignments).await?;
    let now = Utc::now();

    let mut out = Vec::with_capacity(assignments.len());
    for assignment in assignments {
        let quote = assignment
            .questrade_symbol
            .as_ref()
            .and_then(|s| quotes.get(s));
        let decision = match strategy_of(&assignment) {
            Ok(strategy) => {
                let stored = candles_repo::load_recent_candles(
                    &state.db,
                    &assignment.instrument,
                    Granularity::D,
                    Granularity::D.buffer_capacity() as i64,
                )
                .await?;
                match with_today(stored, quote, now) {
                    Ok(candles) => decide(&strategy, &candles, held.get(&assignment.id)),
                    Err(why) => Decision::Unready { why },
                }
            }
            Err(why) => Decision::Unready { why },
        };
        out.push(AssignmentDecision {
            id: assignment.id,
            instrument: assignment.instrument,
            decision,
            quote_delay: quote.and_then(|q| q.delay),
        });
    }
    Ok(Json(out))
}

/// The long-only strategy (Wealthsimple can't short), daily only.
fn strategy_of(assignment: &ShareAlertAssignment) -> Result<Strategy, String> {
    let strategy: Strategy = serde_json::from_value(long_only(&assignment.parameters))
        .map_err(|e| format!("the strategy can't be read: {e}"))?;
    if strategy.granularity != Granularity::D {
        return Err(format!(
            "share alerts are for daily strategies; this one is {}",
            strategy.granularity
        ));
    }
    Ok(strategy)
}

/// Questrade quotes keyed by ticker, in one call.
async fn quotes_for(
    state: &AppState,
    assignments: &[ShareAlertAssignment],
) -> AppResult<HashMap<String, QuoteResult>> {
    let symbols: Vec<&String> = assignments
        .iter()
        .filter_map(|a| a.questrade_symbol.as_ref())
        .collect();
    if symbols.is_empty() {
        return Ok(HashMap::new());
    }
    let Some(qt) = state.questrade.client() else {
        return Err(AppError::Internal("Questrade not configured".into()));
    };
    let mut client = qt.lock().await;
    let mut ids = Vec::new();
    for symbol in &symbols {
        match identity::symbol_id_for(&mut client, &state.db, symbol).await {
            Ok(id) => ids.push(((*symbol).clone(), id)),
            Err(e) => tracing::warn!("share alerts: Questrade could not resolve {symbol}: {e}"),
        }
    }
    let quotes = client
        .get_quotes(&ids.iter().map(|(_, id)| *id).collect::<Vec<_>>())
        .await?;
    drop(client);

    Ok(quotes
        .into_iter()
        .filter_map(|q| {
            let symbol = ids.iter().find(|(_, id)| *id == q.symbol_id)?.0.clone();
            Some((symbol, q))
        })
        .collect())
}

/// The stored bars plus today's so far. When today's bar is already stored
/// (a check after the close) the stored one is used. A quote with no trade
/// today (a holiday, or before the open) has no today to decide on.
fn with_today(
    mut candles: Vec<Candle>,
    quote: Option<&QuoteResult>,
    now: DateTime<Utc>,
) -> Result<Vec<Candle>, String> {
    let today = stock_day_open(now);
    if candles.last().is_some_and(|c| c.time >= today) {
        return Ok(candles);
    }
    let quote = quote.ok_or("no Questrade quote for this market")?;
    let traded_today = quote
        .last_trade_time
        .as_deref()
        .and_then(|t| DateTime::parse_from_rfc3339(t).ok())
        .is_some_and(|t| t.with_timezone(&New_York).date_naive() == ny_day(now));
    let last = quote.last_trade_price.filter(|p| *p > 0.0);
    match (traded_today, last) {
        (true, Some(last)) => {
            candles.push(today_bar(
                today,
                quote.open_price.filter(|p| *p > 0.0).unwrap_or(last),
                quote.high_price.filter(|p| *p > 0.0).unwrap_or(last),
                quote.low_price.filter(|p| *p > 0.0).unwrap_or(last),
                last,
            ));
            Ok(candles)
        }
        _ => Err("no trade today yet (market closed?)".into()),
    }
}

fn ny_day(time: DateTime<Utc>) -> NaiveDate {
    time.with_timezone(&New_York).date_naive()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::TimeZone;

    fn quote(last_trade_time: &str, last: f64) -> QuoteResult {
        QuoteResult {
            symbol: "SPY".into(),
            symbol_id: 1,
            last_trade_price: Some(last),
            last_trade_price_tr_hrs: None,
            last_trade_time: Some(last_trade_time.into()),
            bid_price: None,
            bid_size: None,
            ask_price: None,
            ask_size: None,
            open_price: Some(100.0),
            high_price: Some(102.0),
            low_price: Some(99.0),
            volume: None,
            delay: Some(0),
            is_halted: Some(false),
        }
    }

    fn stored(day: u32) -> Candle {
        let time = New_York
            .with_ymd_and_hms(2026, 10, day, 0, 0, 0)
            .unwrap()
            .with_timezone(&Utc);
        Candle::from_trade_bar(
            time,
            OHLC {
                open: 1.0,
                high: 1.0,
                low: 1.0,
                close: 1.0,
            },
            0.0,
        )
    }

    // 15:45 New York on Friday Oct 30, 2026.
    fn at_1545() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 30, 19, 45, 0).unwrap()
    }

    #[test]
    fn appends_the_day_so_far_from_todays_quote() {
        let q = quote("2026-10-30T15:44:59.000000-04:00", 101.0);
        let candles = with_today(vec![stored(29)], Some(&q), at_1545()).unwrap();
        assert_eq!(candles.len(), 2);
        let today = candles.last().unwrap();
        assert_eq!(today.time, stock_day_open(at_1545()));
        assert_eq!(
            (
                today.mid.open,
                today.mid.high,
                today.mid.low,
                today.mid.close
            ),
            (100.0, 102.0, 99.0, 101.0)
        );
    }

    #[test]
    fn a_stored_today_is_used_as_is() {
        let q = quote("2026-10-30T15:44:59.000000-04:00", 101.0);
        let candles = with_today(vec![stored(29), stored(30)], Some(&q), at_1545()).unwrap();
        assert_eq!(candles.len(), 2);
        assert_eq!(candles[1].mid.close, 1.0);
    }

    #[test]
    fn no_trade_today_is_not_decided() {
        let q = quote("2026-10-29T15:59:59.000000-04:00", 101.0);
        assert!(with_today(vec![stored(29)], Some(&q), at_1545()).is_err());
        assert!(with_today(vec![stored(29)], None, at_1545()).is_err());
    }
}
