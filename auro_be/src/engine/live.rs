use chrono::{DateTime, Timelike, Utc};
use tokio::sync::broadcast;

use crate::engine::types::{CandleAccumulator, CandleBuffer, Granularity, OpenPosition};
use crate::oanda::models::StreamMessage;
use crate::state::{AppState, LastQuote};

pub mod evaluator;
pub mod prefill;
pub mod pricing;
pub mod time;
pub mod trade_management;

pub(crate) use evaluator::{evaluate_strategies, is_trading_enabled, position_key_deltas};
pub use pricing::format_price;
pub(crate) use time::{compute_slot_time, time_slot};

pub const MOVE_TO_BREAKEVEN_PCT: f64 = 0.015;
pub const TRAILING_DISTANCE_PCT: f64 = 0.025;

pub fn spawn_live_evaluator(mut rx: broadcast::Receiver<StreamMessage>, state: AppState) {
    tokio::spawn(async move {
        tracing::info!("Live strategy evaluator started (multi-granularity mode)");

        // Pre-fill buffers from the database for all enabled strategies
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
                            if let Err(e) =
                                trade_management::evaluate_trade_management(&state, pos, mid).await
                            {
                                tracing::error!(
                                    "Trade management error for {} {}: {}",
                                    pos.instrument,
                                    pos.trade_id,
                                    e
                                );
                            }
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
                        // M1 boundary crossed — check each granularity.
                        // D is intentionally excluded: time_slot returns a constant 0 (no
                        // wall-clock day boundary) and the OANDA session day closes at 17:00 ET,
                        // not UTC midnight. D buffers are pre-filled from DB on startup; live
                        // accumulation is deferred until session-aware boundary logic is added.
                        for granularity in &[
                            Granularity::M5,
                            Granularity::M15,
                            Granularity::H1,
                            Granularity::H4,
                        ] {
                            let key = (instrument.clone(), *granularity);

                            let slot = time_slot(*granularity, current_hour, current_minute);

                            let slot_time = compute_slot_time(*granularity, tick_time);

                            let maybe_close = {
                                let mut accumulators = state.live.accumulators.write().await;
                                let accumulator = accumulators
                                    .entry(key.clone())
                                    .or_insert_with(CandleAccumulator::new);
                                accumulator.on_minute_close(slot, slot_time, mid)
                            };

                            let Some(closed_candle) = maybe_close else {
                                continue;
                            };

                            // Candle boundary crossed for this granularity
                            let buffer_snapshot = {
                                let mut buffers = state.live.buffers.write().await;
                                let buffer = buffers.entry(key.clone()).or_insert_with(|| {
                                    CandleBuffer::new(granularity.buffer_capacity())
                                });
                                buffer.push(closed_candle.clone());
                                buffer.current_mid = mid;

                                tracing::debug!(
                                    "{} candle closed for {}: Open={:.5} High={:.5} Low={:.5} Close={:.5}, buffer_len={}",
                                    granularity,
                                    instrument,
                                    closed_candle.open,
                                    closed_candle.high,
                                    closed_candle.low,
                                    closed_candle.close,
                                    buffer.candles.len()
                                );
                                buffer.clone()
                            };

                            if let Err(e) = sqlx::query(
                                r#"INSERT INTO candles (instrument, granularity, timestamp, open, high, low, close, volume, complete)
                                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, true)
                                ON CONFLICT (instrument, granularity, timestamp) DO NOTHING"#
                            )
                            .bind(instrument)
                            .bind(granularity.as_str())
                            .bind(closed_candle.time)
                            .bind(closed_candle.open)
                            .bind(closed_candle.high)
                            .bind(closed_candle.low)
                            .bind(closed_candle.close)
                            .bind(closed_candle.volume)
                            .execute(&state.db)
                            .await
                            {
                                tracing::error!(
                                    "Failed to persist {} candle for {}: {}",
                                    granularity,
                                    instrument,
                                    e
                                );
                            }

                            {
                                // Snapshot rules under read lock so the lock is released
                                // before the (potentially slow) strategy evaluation runs.
                                let rules_snapshot = state.live.rules.read().await.clone();

                                // Evaluate against a snapshot to avoid holding write locks
                                // across DB/OANDA await points inside evaluate_strategies.
                                let before_positions =
                                    state.live.open_positions.read().await.clone();
                                let mut working_positions = before_positions.clone();

                                // Evaluate strategies matching this instrument AND granularity
                                match evaluate_strategies(
                                    &state.db,
                                    &state.oanda,
                                    instrument,
                                    granularity,
                                    &buffer_snapshot,
                                    mid,
                                    &mut working_positions,
                                    &rules_snapshot,
                                )
                                .await
                                {
                                    Ok(reports) => {
                                        // Delta reconciliation is key-based only.
                                        // Value mutations for existing keys are not applied here.
                                        let (removed, added) = position_key_deltas(
                                            &before_positions,
                                            &working_positions,
                                        );
                                        if !removed.is_empty() || !added.is_empty() {
                                            let mut open_positions =
                                                state.live.open_positions.write().await;
                                            for trade_id in removed {
                                                open_positions.remove(&trade_id);
                                            }
                                            for (trade_id, position) in added {
                                                open_positions.insert(trade_id, position);
                                            }
                                        }

                                        if !reports.is_empty() {
                                            tracing::info!(
                                                "Strategy evaluation produced {} signals for {} {}",
                                                reports.len(),
                                                instrument,
                                                granularity
                                            );
                                            for report in &reports {
                                                tracing::debug!("[REPORT] {:?}", report);
                                            }
                                        }
                                    }
                                    Err(e) => {
                                        tracing::error!(
                                            "Strategy evaluation error for {} {}: {}",
                                            instrument,
                                            granularity,
                                            e
                                        );
                                    }
                                }
                            }
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
