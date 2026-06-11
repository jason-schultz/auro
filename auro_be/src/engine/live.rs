use chrono::{DateTime, Timelike, Utc};
use tokio::sync::broadcast;
use tokio::time::{interval, Duration as TokioDuration};

use crate::brokers::oanda::models::{Candlestick, StreamMessage};
use crate::db;
use crate::db::record_signal_event;
use crate::db::repositories::live_queries;
use crate::engine::types::{
    Candle, CandleAccumulator, CandleBuffer, CandleRow, Granularity, OpenPosition, SignalReport,
    OHLC,
};
use crate::state::{AppState, LastQuote};

pub mod account_cache;
pub mod evaluator;
pub mod instrument_cache;
pub mod prefill;
pub mod pricing;
pub mod risk_params;
pub mod sizing;
pub mod time;
pub mod trade_management;

pub(crate) use evaluator::{evaluate_and_apply, is_trading_enabled};
pub use pricing::{format_price, format_price_with_precision};
pub(crate) use time::{compute_slot_time, time_slot};

pub(crate) async fn ingest_closed_candle(
    state: &AppState,
    instrument: &str,
    granularity: Granularity,
    closed: Candle,
    current_mid: f64,
    evaluate: bool,
) -> Vec<SignalReport> {
    let key = (instrument.to_string(), granularity);

    let buffer_snapshot = {
        let mut buffers = state.live.buffers.write().await;
        let buffer = buffers
            .entry(key)
            .or_insert_with(|| CandleBuffer::new(granularity.buffer_capacity()));
        buffer.push(closed.clone());
        buffer.current_mid = current_mid;

        tracing::debug!(
            "{} candle closed for {}: Open={:.5} High={:.5} Low={:.5} Close={:.5}, buffer_len={}",
            granularity,
            instrument,
            closed.mid.open,
            closed.mid.high,
            closed.mid.low,
            closed.mid.close,
            buffer.candles.len()
        );
        buffer.clone()
    };

    let row = CandleRow {
        instrument: instrument.to_string(),
        granularity,
        complete: true,
        candle: closed,
    };

    if let Err(e) = db::upsert_candle(&state.db, &row).await {
        tracing::error!(
            "Failed to persist {} candle for {}: {}",
            granularity,
            instrument,
            e
        );
        return vec![];
    }
    *state.live.last_candle_persisted.write().await = Some(Utc::now());

    if !evaluate {
        return vec![];
    }

    match evaluate_and_apply(
        state,
        instrument,
        granularity,
        &buffer_snapshot,
        current_mid,
    )
    .await
    {
        Ok(reports) => {
            if !reports.is_empty() {
                tracing::info!(
                    "Strategy evaluation produced {} signals for {} {}",
                    reports.len(),
                    instrument,
                    granularity
                );
                for report in &reports {
                    tracing::debug!("[REPORT] {:?}", report);

                    if let Err(e) = record_signal_event(&state.db, report).await {
                        tracing::warn!(
                            "Failed to record signal_event for {} {}: {}",
                            report.instrument,
                            report.granularity,
                            e
                        );
                    }
                }
            }
            reports
        }
        Err(e) => {
            tracing::error!(
                "Strategy evaluation error for {} {}: {}",
                instrument,
                granularity,
                e
            );
            vec![]
        }
    }
}

fn parse_candlestick_data(data: &crate::brokers::oanda::models::CandlestickData) -> Option<OHLC> {
    Some(OHLC {
        open: data.o.parse().ok()?,
        high: data.h.parse().ok()?,
        low: data.l.parse().ok()?,
        close: data.c.parse().ok()?,
    })
}

fn parse_complete_candle(candle: &Candlestick) -> Option<Candle> {
    if !candle.complete {
        return None;
    }

    let time = DateTime::parse_from_rfc3339(&candle.time)
        .ok()?
        .with_timezone(&Utc);
    let mid = parse_candlestick_data(candle.mid.as_ref()?)?;

    Some(Candle {
        time,
        mid,
        volume: candle.volume,
        bid: candle.bid.as_ref().and_then(parse_candlestick_data),
        ask: candle.ask.as_ref().and_then(parse_candlestick_data),
    })
}

fn select_new_complete_candles(
    candles: &[Candlestick],
    last_buffer_time: Option<DateTime<Utc>>,
) -> Vec<Candle> {
    let mut selected: Vec<Candle> = Vec::new();

    for candle in candles {
        let Some(parsed) = parse_complete_candle(candle) else {
            continue;
        };
        let is_newer_than_buffer = last_buffer_time.map(|t| parsed.time > t).unwrap_or(true);
        if !is_newer_than_buffer {
            continue;
        }

        selected.push(parsed);
    }

    selected.sort_by_key(|c| c.time);
    selected
}

fn should_evaluate_polled_candle(index: usize, total: usize) -> bool {
    index + 1 == total
}

pub fn spawn_htf_poller(state: AppState) {
    tokio::spawn(async move {
        tracing::info!("HTF poller started (H4/D from OANDA complete candles)");

        let mut interval = interval(TokioDuration::from_secs(300));

        loop {
            interval.tick().await;

            for granularity in [Granularity::H4, Granularity::D] {
                let instruments = match live_queries::enabled_strategy_instruments_for_granularity(
                    &state.db,
                    granularity.as_str(),
                )
                .await
                {
                    Ok(v) => v,
                    Err(e) => {
                        tracing::warn!(
                            "HTF poller failed to list enabled instruments for {}: {}",
                            granularity,
                            e
                        );
                        continue;
                    }
                };

                for instrument in instruments {
                    let last_buffer_time = {
                        let buffers = state.live.buffers.read().await;
                        buffers
                            .get(&(instrument.clone(), granularity))
                            .and_then(|b| b.candles.last().map(|c| c.time))
                    };

                    let response = match state
                        .oanda
                        .get_candles(&instrument, granularity.as_str(), Some(8), None, None)
                        .await
                    {
                        Ok(r) => r,
                        Err(e) => {
                            tracing::warn!(
                                "HTF poller failed to fetch {} {} candles: {}",
                                instrument,
                                granularity,
                                e
                            );
                            continue;
                        }
                    };

                    let new_closed =
                        select_new_complete_candles(&response.candles, last_buffer_time);

                    if new_closed.is_empty() {
                        continue;
                    }

                    let current_mid = {
                        let quotes = state.live.last_quotes.read().await;
                        quotes.get(&instrument).map(|q| q.mid)
                    };

                    let total_new = new_closed.len();
                    for (i, closed) in new_closed.into_iter().enumerate() {
                        let mid_for_eval = current_mid.unwrap_or(closed.mid.close);
                        let evaluate = should_evaluate_polled_candle(i, total_new);

                        let _ = ingest_closed_candle(
                            &state,
                            &instrument,
                            granularity,
                            closed,
                            mid_for_eval,
                            evaluate,
                        )
                        .await;
                    }
                }
            }
        }
    });
}

pub fn spawn_live_evaluator(mut rx: broadcast::Receiver<StreamMessage>, state: AppState) {
    tokio::spawn(async move {
        tracing::info!("Live strategy evaluator started (multi-granularity mode)");

        // Pre-fill buffers from the database for all strategy rows in the universe
        prefill::run_prefill_buffers(&state).await;
        prefill::run_prefill_open_positions(&state).await;
        prefill::run_prefill_rules(&state).await;

        loop {
            match rx.recv().await {
                Ok(StreamMessage::PRICE(price)) => {
                    let bid: f64 = match price.bids.first() {
                        Some(b) => match b.price.parse() {
                            Ok(v) => v,
                            Err(_) => continue,
                        },
                        None => continue,
                    };
                    let ask: f64 = match price.asks.first() {
                        Some(a) => match a.price.parse() {
                            Ok(v) => v,
                            Err(_) => continue,
                        },
                        None => continue,
                    };
                    let mid = (bid + ask) / 2.0;

                    let tick_time = match DateTime::parse_from_rfc3339(&price.time) {
                        Ok(t) => t.with_timezone(&Utc),
                        Err(_) => continue,
                    };

                    {
                        let mut quotes = state.live.last_quotes.write().await;
                        quotes.insert(
                            price.instrument.clone(),
                            LastQuote {
                                mid,
                                bid,
                                ask,
                                at: tick_time,
                            },
                        );
                    }

                    // Trade management - check open positions on this instrument
                    {
                        let positions_snapshot: Vec<OpenPosition> = {
                            let positions = state.live.open_positions.read().await;
                            positions
                                .values()
                                .filter(|p| p.instrument == price.instrument)
                                .cloned()
                                .collect()
                        };

                        for pos in &positions_snapshot {
                            trade_management::update_mae_mfe(&state, pos, mid).await;
                        }
                    }

                    let current_minute = tick_time.minute();
                    let current_hour = tick_time.hour();
                    let instrument = &price.instrument;

                    // Check if minute rolled over
                    let prev_minute = {
                        let eval_min = state.live.last_eval_minute.read().await;
                        eval_min.get(instrument).copied().unwrap_or(current_minute)
                    };

                    if current_minute != prev_minute {
                        // M1 boundary crossed — check UTC-aligned rollup granularities.
                        // H4 and D are sourced from OANDA complete candles via poller to match
                        // the NY-session anchored historical/backfill alignment.
                        for granularity in &[Granularity::M5, Granularity::M15, Granularity::H1] {
                            let key = (instrument.clone(), *granularity);

                            let slot = time_slot(*granularity, current_hour, current_minute);

                            let slot_time = compute_slot_time(*granularity, tick_time);

                            let maybe_close = {
                                let mut accumulators = state.live.accumulators.write().await;
                                let accumulator = accumulators
                                    .entry(key.clone())
                                    .or_insert_with(CandleAccumulator::new);
                                accumulator.on_minute_close(slot, slot_time, mid, bid, ask)
                            };

                            let Some(closed_candle) = maybe_close else {
                                continue;
                            };

                            let _ = ingest_closed_candle(
                                &state,
                                instrument,
                                *granularity,
                                closed_candle,
                                mid,
                                true,
                            )
                            .await;
                        }
                    }

                    {
                        // Update current_mid on all buffers for this instrument
                        let mut buffers = state.live.buffers.write().await;
                        for granularity in &[
                            Granularity::M5,
                            Granularity::M15,
                            Granularity::H1,
                            Granularity::H4,
                            Granularity::D,
                        ] {
                            let key = (instrument.clone(), *granularity);
                            if let Some(buffer) = buffers.get_mut(&key) {
                                buffer.current_mid = mid;
                            }
                        }
                    }

                    {
                        let mut eval_min = state.live.last_eval_minute.write().await;
                        eval_min.insert(instrument.clone(), current_minute);
                    }
                }
                Ok(StreamMessage::HEARTBEAT(_)) => {}
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    tracing::warn!("Live evaluator lagged, skipped {} messages", n);
                }
                Err(broadcast::error::RecvError::Closed) => {
                    tracing::info!("Live evaluator channel closed");
                    break;
                }
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_candle(time: &str, complete: bool, close: &str) -> Candlestick {
        let data = crate::brokers::oanda::models::CandlestickData {
            o: close.to_string(),
            h: close.to_string(),
            l: close.to_string(),
            c: close.to_string(),
        };

        Candlestick {
            time: time.to_string(),
            complete,
            volume: 1,
            mid: Some(crate::brokers::oanda::models::CandlestickData {
                o: data.o.clone(),
                h: data.h.clone(),
                l: data.l.clone(),
                c: data.c.clone(),
            }),
            bid: Some(crate::brokers::oanda::models::CandlestickData {
                o: data.o.clone(),
                h: data.h.clone(),
                l: data.l.clone(),
                c: data.c.clone(),
            }),
            ask: Some(data),
        }
    }

    #[test]
    fn select_new_complete_candles_respects_complete_and_timestamp() {
        let last = DateTime::parse_from_rfc3339("2026-06-01T21:00:00Z")
            .unwrap()
            .with_timezone(&Utc);

        let candles = vec![
            mk_candle("2026-06-01T21:00:00Z", true, "100.0"),
            mk_candle("2026-06-02T01:00:00Z", false, "101.0"),
            mk_candle("2026-06-02T05:00:00Z", true, "102.0"),
        ];

        let picked = select_new_complete_candles(&candles, Some(last));
        assert_eq!(picked.len(), 1);
        assert_eq!(
            picked[0].time,
            DateTime::parse_from_rfc3339("2026-06-02T05:00:00Z")
                .unwrap()
                .with_timezone(&Utc)
        );
        assert_eq!(picked[0].mid.close, 102.0);

        let multi_new = vec![
            mk_candle("2026-06-02T01:00:00Z", true, "101.0"),
            mk_candle("2026-06-02T05:00:00Z", true, "102.0"),
        ];
        let picked_multi = select_new_complete_candles(&multi_new, Some(last));
        assert_eq!(picked_multi.len(), 2);
        assert!(picked_multi[0].time < picked_multi[1].time);

        let stale_only = vec![
            mk_candle("2026-06-01T21:00:00Z", true, "100.0"),
            mk_candle("2026-06-02T01:00:00Z", false, "101.0"),
        ];
        assert!(select_new_complete_candles(&stale_only, Some(last)).is_empty());
    }

    #[test]
    fn should_evaluate_polled_candle_only_for_latest() {
        assert!(!should_evaluate_polled_candle(0, 3));
        assert!(!should_evaluate_polled_candle(1, 3));
        assert!(should_evaluate_polled_candle(2, 3));
        assert!(should_evaluate_polled_candle(0, 1));
    }
}
