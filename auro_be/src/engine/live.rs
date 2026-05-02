use chrono::{DateTime, Timelike, Utc};
use sqlx::PgPool;
use std::collections::HashMap;
use tokio::sync::broadcast;

use crate::engine::mean_reversion::{self, MRSignal, MeanReversionParams};
use crate::engine::trend_following::{self, TFSignal, TrendFollowingParams};
use crate::engine::types::{
    BufferKey, Candle, CandleAccumulator, CandleBuffer, Direction, Granularity, LiveStrategy,
    OpenPosition, SignalAction, SignalReport, StopLossState,
};
use crate::oanda;
use crate::oanda::client::OandaClient;
use crate::oanda::models::StreamMessage;
use crate::state::{AppState, LastQuote};

const MOVE_TO_BREAKEVEN_PCT: f64 = 0.015;
const TRAILING_DISTANCE_PCT: f64 = 0.025;

/// Calculate the time slot for a given granularity.
/// H1: just the hour (0-23), changes every 60 minutes
/// M15: hour * 4 + (minute / 15), changes every 15 minutes (0-95)
/// M5: hour * 12 + (minute / 5), changes every 5 minutes (0-287)
fn time_slot(granularity: Granularity, hour: u32, minute: u32) -> u32 {
    match granularity {
        Granularity::M1 => hour * 60 + minute,
        Granularity::M5 => hour * 12 + minute / 5,
        Granularity::M15 => hour * 4 + minute / 15,
        Granularity::H1 => hour,
        Granularity::H4 => hour / 4,
        Granularity::D => 0,
    }
}

pub fn spawn_live_evaluator(mut rx: broadcast::Receiver<StreamMessage>, state: AppState) {
    tokio::spawn(async move {
        tracing::info!("Live strategy evaluator started (multi-granularity mode)");

        // Pre-fill buffers from the database for all enabled strategies
        run_prefill_buffers(&state).await;
        run_prefill_open_positions(&state).await;

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
                            if let Err(e) = evaluate_trade_management(&state, pos, mid).await {
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
                        // M1 boundary crossed — check each granularity
                        for granularity in &[Granularity::M15, Granularity::H1] {
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
                                let buffer = buffers
                                    .entry(key.clone())
                                    .or_insert_with(|| CandleBuffer::new(200));
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
                            .bind(closed_candle.volume as i32)
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
                                let mut open_positions = state.live.open_positions.write().await;
                                // Evaluate strategies matching this instrument AND granularity
                                match evaluate_strategies(
                                    &state.db,
                                    &state.oanda,
                                    instrument,
                                    granularity,
                                    &buffer_snapshot,
                                    mid,
                                    bid,
                                    ask,
                                    &mut *open_positions,
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
                        for granularity in &[Granularity::M15, Granularity::H1] {
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

async fn run_prefill_buffers(state: &AppState) {
    let mut buffers = state.live.buffers.write().await;

    match prefill_buffers(&state.db, &mut *buffers).await {
        Ok(count) => {
            tracing::info!(
                "Pre-filled buffers for {} instrument/granularity pairs",
                count
            );
        }
        Err(e) => {
            tracing::warn!("Failed to pre-fill buffers: {}", e);
        }
    }
}
/// Pre-fill candle buffers from the database for all enabled strategies.
/// Loads up to 200 candles per (instrument, granularity) pair.
async fn prefill_buffers(
    pool: &PgPool,
    buffers: &mut HashMap<BufferKey, CandleBuffer>,
) -> Result<usize, Box<dyn std::error::Error>> {
    // Get distinct (instrument, granularity) pairs from enabled strategies
    let pairs: Vec<(String, Granularity)> = sqlx::query_as(
        "SELECT DISTINCT instrument, granularity FROM live_strategies WHERE enabled = true",
    )
    .fetch_all(pool)
    .await?;
    let mut count = 0;

    for (instrument, granularity) in &pairs {
        let rows: Vec<(DateTime<Utc>, f64, f64, f64, f64, i32)> = sqlx::query_as(
            r#"
            SELECT timestamp, open, high, low, close, volume
            FROM candles
            WHERE instrument = $1 AND granularity = $2
            ORDER BY timestamp DESC
            LIMIT 200
            "#,
        )
        .bind(instrument)
        .bind(granularity.as_str())
        .fetch_all(pool)
        .await?;

        if rows.is_empty() {
            tracing::warn!(
                "No {} candle data found for {}, skipping pre-fill",
                granularity,
                instrument
            );
            continue;
        }

        let key = (instrument.clone(), *granularity);
        let buffer = buffers.entry(key).or_insert_with(|| CandleBuffer::new(200));

        // Rows come in DESC order (newest first), reverse to get chronological order
        for (time, open, high, low, close, volume) in rows.iter().rev() {
            buffer.push(Candle {
                time: *time,
                open: *open,
                high: *high,
                low: *low,
                close: *close,
                volume: *volume as u32,
            });
        }

        tracing::info!(
            "Pre-filled {} {} candles for {}",
            buffer.candles.len(),
            granularity,
            instrument
        );

        count += 1;
    }

    Ok(count)
}

pub(crate) async fn is_trading_enabled(pool: &PgPool) -> bool {
    let result: Option<(serde_json::Value,)> =
        sqlx::query_as("SELECT value FROM trading_config WHERE key = 'trading_enabled'")
            .fetch_optional(pool)
            .await
            .unwrap_or(None);

    result
        .and_then(|r| r.0.as_str().map(|s| s == "true"))
        .unwrap_or(false)
}

async fn run_prefill_open_positions(state: &AppState) {
    let mut positions = state.live.open_positions.write().await;
    match prefill_open_positions(&state.db, &state.oanda, &mut *positions).await {
        Ok(count) => tracing::info!("Pre-filled {} open positions from OANDA", count),
        Err(e) => tracing::error!("Failed to pre-fill open positions: {}", e),
    }
}

async fn prefill_open_positions(
    pool: &PgPool,
    oanda: &OandaClient,
    open_positions: &mut HashMap<String, OpenPosition>,
) -> Result<usize, Box<dyn std::error::Error>> {
    let oanda_trades = oanda.get_open_trades().await?;
    let trades = oanda_trades["trades"]
        .as_array()
        .ok_or("OANDA get_open_trades did not return a JSON array")?;

    let mut count = 0;
    for trade in trades {
        let trade_id = trade["id"].as_str().ok_or("trade missing id")?;
        let units = trade["currentUnits"].as_str().unwrap_or("0").to_string();

        let row: Option<(uuid::Uuid, String, Direction, f64, String, String)> = sqlx::query_as(
            "SELECT lt.live_strategy_id, lt.instrument, lt.direction, lt.entry_price, \
            lt.oanda_trade_id, ls.strategy_type \
            FROM live_trades lt \
            JOIN live_strategies ls ON ls.id = lt.live_strategy_id \
            WHERE lt.oanda_trade_id = $1 AND lt.status = 'open'",
        )
        .bind(trade_id)
        .fetch_optional(pool)
        .await?;

        let Some((strategy_id, instrument, direction, entry_price, db_trade_id, strategy_type)) =
            row
        else {
            tracing::warn!(
                "OANDA has open trade {} but no matching live_trades row — skipping",
                trade_id
            );
            continue;
        };

        open_positions.insert(
            trade_id.to_string(),
            OpenPosition {
                strategy_id,
                trade_id: db_trade_id,
                instrument,
                direction,
                entry_price,
                units,
                stop_loss_state: determine_stop_loss_state(
                    trade,
                    strategy_type.as_str(),
                    entry_price,
                ),
            },
        );
        count += 1;
    }

    Ok(count)
}

pub(crate) async fn evaluate_strategies(
    pool: &PgPool,
    oanda: &OandaClient,
    instrument: &str,
    granularity: &Granularity,
    buffer: &CandleBuffer,
    current_price: f64,
    bid: f64,
    ask: f64,
    open_positions: &mut HashMap<String, OpenPosition>,
) -> Result<Vec<SignalReport>, Box<dyn std::error::Error>> {
    if !is_trading_enabled(pool).await {
        return Ok(vec![]);
    }

    let strategies: Vec<LiveStrategy> = sqlx::query_as(
        "SELECT id, strategy_type, instrument, granularity, parameters, enabled, max_position_size \
         FROM live_strategies WHERE instrument = $1 AND granularity = $2 AND enabled = true"
    )
    .bind(instrument)
    .bind(granularity.as_str())
    .fetch_all(pool)
    .await?;

    let mut reports: Vec<SignalReport> = Vec::new();

    for strategy in &strategies {
        let has_position = open_positions
            .values()
            .any(|p| p.strategy_id == strategy.id);

        if has_position {
            let exit_reports =
                evaluate_exit(pool, oanda, strategy, current_price, buffer, open_positions).await?;
            reports.extend(exit_reports);
        } else {
            if let Some(entry_report) = evaluate_entry(
                pool,
                oanda,
                strategy,
                current_price,
                bid,
                ask,
                buffer,
                open_positions,
            )
            .await?
            {
                reports.push(entry_report);
            }
        }
    }

    Ok(reports)
}

async fn evaluate_entry(
    pool: &PgPool,
    oanda: &OandaClient,
    strategy: &LiveStrategy,
    current_price: f64,
    bid: f64,
    ask: f64,
    buffer: &CandleBuffer,
    open_positions: &mut HashMap<String, OpenPosition>,
) -> Result<Option<SignalReport>, Box<dyn std::error::Error>> {
    let params = &strategy.parameters;

    let already_open = open_positions
        .values()
        .any(|pos| pos.instrument == strategy.instrument);

    if already_open {
        tracing::debug!(
            "[SKIP ENTRY] {} {} - position already open on this instrument",
            strategy.instrument,
            strategy.granularity
        );
        return Ok(Some(SignalReport {
            strategy_id: strategy.id,
            strategy_type: strategy.strategy_type.clone(),
            instrument: strategy.instrument.clone(),
            granularity: strategy.granularity,
            action: SignalAction::EntryRejected,
            price: current_price,
            reason: "position_already_open".to_string(),
            oanda_trade_id: None,
        }));
    }

    match strategy.strategy_type.as_str() {
        "mean_reversion" => {
            let mr_params = MeanReversionParams {
                ma_period: params["ma_period"].as_u64().unwrap_or(20) as usize,
                entry_threshold: params["entry_threshold"].as_f64().unwrap_or(-0.01),
                exit_threshold: params["exit_threshold"].as_f64().unwrap_or(0.003),
                stop_loss: params["stop_loss"].as_f64().unwrap_or(-0.005),
            };

            let closes = buffer.closes();

            // Diagnostic: compute MA and deviation for logging
            if closes.len() >= mr_params.ma_period {
                let ma: f64 = closes[closes.len() - mr_params.ma_period..]
                    .iter()
                    .sum::<f64>()
                    / mr_params.ma_period as f64;
                let deviation = (current_price - ma) / ma;
                tracing::info!(
                    "[STATUS] MR {} {} | price={:.5} MA{}={:.5} dev={:.4}% (need {:.4}%) | buf={}",
                    strategy.instrument,
                    strategy.granularity,
                    current_price,
                    mr_params.ma_period,
                    ma,
                    deviation * 100.0,
                    mr_params.entry_threshold * 100.0,
                    closes.len(),
                );
            } else {
                tracing::info!(
                    "[STATUS] MR {} {} | buffer {}/{} — waiting for data",
                    strategy.instrument,
                    strategy.granularity,
                    closes.len(),
                    mr_params.ma_period,
                );
            }

            match mean_reversion::check_entry(&closes, &mr_params) {
                MRSignal::Enter {
                    ma_value,
                    deviation_pct,
                } => {
                    tracing::info!(
                        "[SIGNAL] Mean reversion entry on {} ({}): price={:.5}, MA{}={:.5}, deviation={:.4}%",
                        strategy.instrument, strategy.granularity, current_price, mr_params.ma_period, ma_value, deviation_pct * 100.0
                    );

                    let sl_price = current_price * (1.0 + mr_params.stop_loss);
                    let tp_price = current_price * (1.0 + mr_params.exit_threshold);

                    return execute_entry(
                        pool,
                        oanda,
                        strategy,
                        &Direction::Long,
                        &strategy.max_position_size,
                        current_price,
                        sl_price,
                        Some(tp_price),
                        &format!(
                            "BelowMA: MA{}={:.5}, deviation={:.4}%",
                            mr_params.ma_period,
                            ma_value,
                            deviation_pct * 100.0
                        ),
                        open_positions,
                    )
                    .await;
                }
                _ => {}
            }
        }
        "trend_following" => {
            let tf_params = TrendFollowingParams {
                fast_period: params["fast_period"].as_u64().unwrap_or(10) as usize,
                slow_period: params["slow_period"].as_u64().unwrap_or(50) as usize,
                stop_loss: params["stop_loss"].as_f64().unwrap_or(-0.02),
                take_profit: params["take_profit"].as_f64(),
            };

            let closes = buffer.closes();

            // Diagnostic: compute fast/slow MAs for logging
            if closes.len() >= tf_params.slow_period {
                let fast_ma: f64 = closes[closes.len() - tf_params.fast_period..]
                    .iter()
                    .sum::<f64>()
                    / tf_params.fast_period as f64;
                let slow_ma: f64 = closes[closes.len() - tf_params.slow_period..]
                    .iter()
                    .sum::<f64>()
                    / tf_params.slow_period as f64;
                let gap_pct = (fast_ma - slow_ma) / slow_ma * 100.0;
                let side = if fast_ma > slow_ma { "ABOVE" } else { "BELOW" };
                tracing::info!(
                    "[STATUS] TF {} {} | F{}={:.5} S{}={:.5} gap={:.4}% ({}) | buf={}",
                    strategy.instrument,
                    strategy.granularity,
                    tf_params.fast_period,
                    fast_ma,
                    tf_params.slow_period,
                    slow_ma,
                    gap_pct,
                    side,
                    closes.len(),
                );
            } else {
                tracing::info!(
                    "[STATUS] TF {} {} | buffer {}/{} — waiting for data",
                    strategy.instrument,
                    strategy.granularity,
                    closes.len(),
                    tf_params.slow_period,
                );
            }

            match trend_following::check_entry(&closes, &tf_params) {
                TFSignal::EnterLong { fast_ma, slow_ma } => {
                    tracing::info!(
                        "[SIGNAL] Trend following LONG on {} ({}): fast_ma={:.5}, slow_ma={:.5}",
                        strategy.instrument,
                        strategy.granularity,
                        fast_ma,
                        slow_ma
                    );

                    let sl_price = current_price * (1.0 + tf_params.stop_loss);
                    let tp_price = tf_params.take_profit.map(|tp| current_price * (1.0 + tp));

                    return execute_entry(
                        pool,
                        oanda,
                        strategy,
                        &Direction::Long,
                        &strategy.max_position_size,
                        current_price,
                        sl_price,
                        tp_price,
                        &format!("CrossAbove: fast_ma={:.5}, slow_ma={:.5}", fast_ma, slow_ma),
                        open_positions,
                    )
                    .await;
                }
                TFSignal::EnterShort { fast_ma, slow_ma } => {
                    tracing::info!(
                        "[SIGNAL] Trend following SHORT on {} ({}): fast_ma={:.5}, slow_ma={:.5}",
                        strategy.instrument,
                        strategy.granularity,
                        fast_ma,
                        slow_ma
                    );

                    let sl_price = current_price * (1.0 - tf_params.stop_loss);
                    let tp_price = tf_params.take_profit.map(|tp| current_price * (1.0 - tp));
                    let short_units = format!("-{}", strategy.max_position_size);

                    return execute_entry(
                        pool,
                        oanda,
                        strategy,
                        &Direction::Short,
                        &short_units,
                        current_price,
                        sl_price,
                        tp_price,
                        &format!("CrossBelow: fast_ma={:.5}, slow_ma={:.5}", fast_ma, slow_ma),
                        open_positions,
                    )
                    .await;
                }
                _ => {}
            }
        }
        _ => {}
    }
    Ok(None)
}

async fn execute_entry(
    pool: &PgPool,
    oanda: &OandaClient,
    strategy: &LiveStrategy,
    direction: &Direction,
    units: &str,
    current_price: f64,
    sl_price: f64,
    tp_price: Option<f64>,
    entry_reason: &str,
    open_positions: &mut HashMap<String, OpenPosition>,
) -> Result<Option<SignalReport>, Box<dyn std::error::Error>> {
    let sl_str = format_price(&strategy.instrument, sl_price);
    let tp_str = tp_price.map(|p| format_price(&strategy.instrument, p));

    match oanda
        .create_market_order(
            &strategy.instrument,
            units,
            Some(&sl_str),
            tp_str.as_deref(),
        )
        .await
    {
        Ok(resp) => {
            let trade_id = resp["orderFillTransaction"]["tradeOpened"]["tradeID"]
                .as_str()
                .unwrap_or("unknown")
                .to_string();

            let fill_price = resp["orderFillTransaction"]["price"]
                .as_str()
                .and_then(|p| p.parse::<f64>().ok())
                .unwrap_or(current_price);

            tracing::info!(
                "[TRADE] Opened {} {} ({}) @ {:.5}, SL={}, TP={}, trade_id={}",
                direction,
                strategy.instrument,
                strategy.granularity,
                fill_price,
                sl_str,
                tp_str.as_deref().unwrap_or("none"),
                trade_id
            );

            sqlx::query(
                r#"INSERT INTO live_trades
                    (live_strategy_id, oanda_trade_id, instrument, direction, units,
                     entry_price, stop_loss_price, take_profit_price, entry_reason, status)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'open')"#,
            )
            .bind(strategy.id)
            .bind(&trade_id)
            .bind(&strategy.instrument)
            .bind(direction)
            .bind(units)
            .bind(fill_price)
            .bind(sl_price)
            .bind(tp_price)
            .bind(entry_reason)
            .execute(pool)
            .await?;

            let action = match direction {
                Direction::Long => SignalAction::OpenedLong,
                Direction::Short => SignalAction::OpenedShort,
            };

            let report = SignalReport {
                strategy_id: strategy.id,
                strategy_type: strategy.strategy_type.clone(),
                instrument: strategy.instrument.clone(),
                granularity: strategy.granularity,
                action,
                price: current_price,
                reason: entry_reason.to_string(),
                oanda_trade_id: Some(trade_id.clone()),
            };

            open_positions.insert(
                trade_id.to_string(),
                OpenPosition {
                    strategy_id: strategy.id,
                    trade_id,
                    instrument: strategy.instrument.clone(),
                    direction: *direction,
                    entry_price: fill_price,
                    units: units.to_string(),
                    stop_loss_state: StopLossState::initial_for_strategy_type(
                        &strategy.strategy_type,
                    ),
                },
            );

            Ok(Some(report))
        }
        Err(e) => {
            tracing::error!(
                "[ORDER FAILED] {} {} ({}): {}",
                direction,
                strategy.instrument,
                strategy.granularity,
                e
            );
            Ok(None)
        }
    }
}

async fn evaluate_exit(
    pool: &PgPool,
    oanda: &OandaClient,
    strategy: &LiveStrategy,
    current_price: f64,
    buffer: &CandleBuffer,
    open_positions: &mut HashMap<String, OpenPosition>,
) -> Result<Vec<SignalReport>, Box<dyn std::error::Error>> {
    let positions_for_strategy: Vec<OpenPosition> = open_positions
        .values()
        .filter(|p| p.strategy_id == strategy.id)
        .cloned()
        .collect();

    if positions_for_strategy.is_empty() {
        return Ok(vec![]);
    }

    let params = &strategy.parameters;
    let mut should_exit = false;
    let mut exit_reason = String::new();

    match strategy.strategy_type.as_str() {
        "mean_reversion" => {
            // Exits are managed OANDA-side SL/TP orders; reconciler syncs DB.
            // No rust exit checks needed on this arm
            return Ok(vec![]);
        }
        "trend_following" => {
            let tf_params = TrendFollowingParams {
                fast_period: params["fast_period"].as_u64().unwrap_or(10) as usize,
                slow_period: params["slow_period"].as_u64().unwrap_or(50) as usize,
                stop_loss: params["stop_loss"].as_f64().unwrap_or(-0.02),
                take_profit: params["take_profit"].as_f64(),
            };

            let is_long = positions_for_strategy[0].direction == Direction::Long;
            let closes = buffer.closes();

            match trend_following::check_exit(&closes, &tf_params, is_long) {
                TFSignal::ExitTrendReversal { fast_ma, slow_ma } => {
                    should_exit = true;
                    exit_reason = format!(
                        "TrendReversal: fast_ma={:.5}, slow_ma={:.5}",
                        fast_ma, slow_ma
                    );
                }
                _ => {}
            }
        }
        _ => {}
    }

    let mut reports = Vec::<SignalReport>::new();

    if should_exit {
        for pos in &positions_for_strategy {
            let trade_id = pos.trade_id.clone();
            let direction = pos.direction;
            let entry_price = pos.entry_price;
            let instrument = pos.instrument.clone();

            tracing::info!(
                "[EXIT SIGNAL] {} on {} ({}): {}",
                direction,
                instrument,
                strategy.granularity,
                exit_reason
            );

            match oanda.close_trade(&trade_id, None).await {
                Ok(resp) => {
                    let fill_price = resp["orderFillTransaction"]["price"]
                        .as_str()
                        .and_then(|p| p.parse::<f64>().ok())
                        .unwrap_or(current_price);

                    let pnl = match direction {
                        Direction::Long => (fill_price - entry_price) / entry_price,
                        Direction::Short => (entry_price - fill_price) / entry_price,
                    };

                    tracing::info!(
                        "[TRADE CLOSED] {} {} ({}) @ {:.5}, PnL={:.4}%, reason={}",
                        direction,
                        instrument,
                        strategy.granularity,
                        fill_price,
                        pnl * 100.0,
                        exit_reason
                    );

                    sqlx::query(
                        r#"UPDATE live_trades
                        SET exit_price = $1, exit_time = NOW(), pnl_percent = $2,
                            exit_reason = $3, status = 'closed', updated_at = NOW()
                        WHERE oanda_trade_id = $4"#,
                    )
                    .bind(fill_price)
                    .bind(pnl)
                    .bind(&exit_reason)
                    .bind(&trade_id)
                    .execute(pool)
                    .await?;

                    open_positions.remove(&trade_id);

                    let action = match direction {
                        Direction::Long => SignalAction::ClosedLong,
                        Direction::Short => SignalAction::ClosedShort,
                    };

                    reports.push(SignalReport {
                        strategy_id: strategy.id,
                        strategy_type: strategy.strategy_type.clone(),
                        instrument: instrument.clone(),
                        granularity: strategy.granularity,
                        action,
                        price: fill_price,
                        reason: exit_reason.clone(),
                        oanda_trade_id: Some(trade_id.clone()),
                    });
                }
                Err(e) => {
                    tracing::error!("[CLOSE FAILED] {} {}: {}", direction, instrument, e);
                }
            }
        }
    }

    Ok(reports)
}

/// Returns the number of decimal places OANDA expects for price strings on a given instrument.
pub fn price_precision(instrument: &str) -> usize {
    if instrument.ends_with("_JPY") {
        return 3;
    }
    if matches!(
        instrument,
        "SPX500_USD"
            | "NAS100_USD"
            | "US30_USD"
            | "US2000_USD"
            | "UK100_GBP"
            | "DE30_EUR"
            | "FR40_EUR"
            | "EU50_EUR"
            | "JP225_USD"
            | "AU200_AUD"
            | "HK33_HKD"
            | "CN50_USD"
            | "TWIX_USD"
            | "IN50_USD"
    ) {
        return 1;
    }
    if matches!(instrument, "XAU_USD" | "XPT_USD" | "XPD_USD") {
        return 2;
    }
    if instrument.starts_with("XAG_") {
        return 4;
    }
    if matches!(instrument, "BCO_USD" | "WTICO_USD") {
        return 3;
    }
    if instrument == "NATGAS_USD" {
        return 4;
    }
    if instrument == "XCU_USD" {
        return 4;
    }
    if instrument.starts_with("USB")
        || instrument.starts_with("UK10")
        || instrument.starts_with("DE10")
    {
        return 3;
    }
    5
}

/// Format a price for an OANDA order at the correct precision for the instrument.
pub fn format_price(instrument: &str, price: f64) -> String {
    format!("{:.*}", price_precision(instrument), price)
}

/// Returns the canonical start time of the slot containing `tick_time`.
fn compute_slot_time(granularity: Granularity, tick_time: DateTime<Utc>) -> DateTime<Utc> {
    match granularity {
        Granularity::H1 => tick_time
            .with_minute(0)
            .unwrap()
            .with_second(0)
            .unwrap()
            .with_nanosecond(0)
            .unwrap(),
        Granularity::M15 => {
            let m = (tick_time.minute() / 15) * 15;
            tick_time
                .with_minute(m)
                .unwrap()
                .with_second(0)
                .unwrap()
                .with_nanosecond(0)
                .unwrap()
        }
        Granularity::D | Granularity::H4 | Granularity::M5 | Granularity::M1 => {
            unimplemented!("compute_slot_time not implemented for {:?}", granularity)
        }
    }
}

async fn evaluate_trade_management(
    state: &AppState,
    position: &OpenPosition,
    current_price: f64,
) -> Result<(), Box<dyn std::error::Error>> {
    // Skip if not eligible for management or already at terminal state
    if matches!(
        position.stop_loss_state,
        StopLossState::NotApplicable | StopLossState::Trailing
    ) {
        return Ok(());
    }

    // Compute % move from entry, direction-aware
    // Long: profit when price > entry. Short: profit when price < entry.
    let pct_in_profit = match position.direction {
        Direction::Long => (current_price - position.entry_price) / position.entry_price,
        Direction::Short => (position.entry_price - current_price) / position.entry_price,
    };

    match position.stop_loss_state {
        StopLossState::Initial => {
            // Move SL to breakeven (entry price) once trade is up X%
            if pct_in_profit >= MOVE_TO_BREAKEVEN_PCT {
                let sl_str = format_price(&position.instrument, position.entry_price);

                tracing::info!(
                    "[MGMT] {} {} ({}) up {:.2}% — moving SL to breakeven @ {}",
                    position.direction,
                    position.instrument,
                    position.trade_id,
                    pct_in_profit * 100.0,
                    sl_str
                );

                state
                    .oanda
                    .modify_trade_stop_loss(&position.trade_id, &sl_str)
                    .await?;

                // Update in-memory state
                let mut positions = state.live.open_positions.write().await;
                if let Some(p) = positions.get_mut(&position.trade_id) {
                    p.stop_loss_state = StopLossState::Breakeven;
                }
            }
        }
        StopLossState::Breakeven => {
            // Transition to trailing stop once trade is up the trailing distance + breakeven buffer
            // We require pct_in_profit >= MOVE_TO_BREAKEVEN_PCT + TRAILING_DISTANCE_PCT so that
            // the trailing stop, when first attached, sits above the breakeven SL.
            // Otherwise the trailing stop would immediately trigger below entry.
            let trailing_threshold = MOVE_TO_BREAKEVEN_PCT + TRAILING_DISTANCE_PCT;

            if pct_in_profit >= trailing_threshold {
                let distance_price = current_price * TRAILING_DISTANCE_PCT;
                let distance_str = format_price(&position.instrument, distance_price);

                tracing::info!(
                    "[MGMT] {} {} ({}) up {:.2}% — replacing SL with trailing @ distance {}",
                    position.direction,
                    position.instrument,
                    position.trade_id,
                    pct_in_profit * 100.0,
                    distance_str
                );

                state
                    .oanda
                    .replace_with_trailing_stop(&position.trade_id, &distance_str)
                    .await?;

                let mut positions = state.live.open_positions.write().await;
                if let Some(p) = positions.get_mut(&position.trade_id) {
                    p.stop_loss_state = StopLossState::Trailing;
                }
            }
        }
        StopLossState::Trailing | StopLossState::NotApplicable => {
            // Already handled by early return above; this arm is unreachable but
            // keeps the match exhaustive for future enum additions.
        }
    }

    Ok(())
}

fn determine_stop_loss_state(
    trade: &serde_json::Value,
    strategy_type: &str,
    entry_price: f64,
) -> StopLossState {
    match strategy_type {
        "mean_reversion" => return StopLossState::NotApplicable,
        "trend_following" => {}
        _ => return StopLossState::NotApplicable,
    }

    // Trailing stop present -> already in trailing state
    if trade.get("trailingStopLossOrder").is_some() {
        return StopLossState::Trailing;
    }

    // Fixed SL present, check if it's at entry price (within precision tolerance)
    if let Some(sl) = trade.get("stopLossOrder") {
        if let Some(sl_price) = sl["price"].as_str().and_then(|s| s.parse::<f64>().ok()) {
            // Use a small tolerance because of price formatting precision
            if (sl_price - entry_price).abs() / entry_price < 0.0001 {
                return StopLossState::Breakeven;
            }
        }
    }

    StopLossState::Initial
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- price_precision tests ---

    #[test]
    fn forex_majors_use_5_decimals() {
        assert_eq!(price_precision("EUR_USD"), 5);
        assert_eq!(price_precision("GBP_USD"), 5);
        assert_eq!(price_precision("AUD_USD"), 5);
        assert_eq!(price_precision("USD_CAD"), 5);
    }

    #[test]
    fn jpy_pairs_use_3_decimals() {
        assert_eq!(price_precision("USD_JPY"), 3);
        assert_eq!(price_precision("EUR_JPY"), 3);
        assert_eq!(price_precision("GBP_JPY"), 3);
        assert_eq!(price_precision("CHF_JPY"), 3);
    }

    #[test]
    fn indices_use_1_decimal() {
        assert_eq!(price_precision("UK100_GBP"), 1);
        assert_eq!(price_precision("SPX500_USD"), 1);
        assert_eq!(price_precision("NAS100_USD"), 1);
        assert_eq!(price_precision("DE30_EUR"), 1);
        assert_eq!(price_precision("EU50_EUR"), 1);
        assert_eq!(price_precision("AU200_AUD"), 1);
    }

    #[test]
    fn gold_platinum_palladium_use_2_decimals() {
        assert_eq!(price_precision("XAU_USD"), 2);
        assert_eq!(price_precision("XPT_USD"), 2);
        assert_eq!(price_precision("XPD_USD"), 2);
    }

    #[test]
    fn silver_uses_4_decimals() {
        assert_eq!(price_precision("XAG_USD"), 4);
    }

    #[test]
    fn oil_uses_3_decimals() {
        assert_eq!(price_precision("WTICO_USD"), 3);
        assert_eq!(price_precision("BCO_USD"), 3);
    }

    #[test]
    fn natural_gas_uses_4_decimals() {
        assert_eq!(price_precision("NATGAS_USD"), 4);
    }

    #[test]
    fn unknown_instrument_defaults_to_5() {
        assert_eq!(price_precision("SOME_UNKNOWN"), 5);
    }

    // --- format_price tests ---

    #[test]
    fn format_price_rounds_uk100_to_1_decimal() {
        let formatted = format_price("UK100_GBP", 10606.12345);
        assert_eq!(formatted, "10606.1");
    }

    #[test]
    fn format_price_keeps_forex_at_5_decimals() {
        let formatted = format_price("EUR_USD", 1.12345);
        assert_eq!(formatted, "1.12345");
    }

    #[test]
    fn format_price_jpy_pair_at_3_decimals() {
        let formatted = format_price("USD_JPY", 148.12345);
        assert_eq!(formatted, "148.123");
    }

    #[test]
    fn format_price_gold_at_2_decimals() {
        let formatted = format_price("XAU_USD", 3245.6789);
        assert_eq!(formatted, "3245.68");
    }

    #[test]
    fn format_price_rounds_not_truncates() {
        assert_eq!(format_price("EUR_USD", 1.123456), "1.12346");
        assert_eq!(format_price("XAU_USD", 3245.678), "3245.68");
    }

    // --- time_slot tests ---

    #[test]
    fn time_slot_h1_returns_hour() {
        assert_eq!(time_slot(Granularity::H1, 0, 0), 0);
        assert_eq!(time_slot(Granularity::H1, 14, 30), 14);
        assert_eq!(time_slot(Granularity::H1, 23, 59), 23);
    }

    #[test]
    fn time_slot_m15_changes_every_15_minutes() {
        // Hour 0
        assert_eq!(time_slot(Granularity::M15, 0, 0), 0);
        assert_eq!(time_slot(Granularity::M15, 0, 14), 0); // still in first 15-min block
        assert_eq!(time_slot(Granularity::M15, 0, 15), 1); // new block
        assert_eq!(time_slot(Granularity::M15, 0, 30), 2);
        assert_eq!(time_slot(Granularity::M15, 0, 45), 3);
        // Hour 1
        assert_eq!(time_slot(Granularity::M15, 1, 0), 4);
        assert_eq!(time_slot(Granularity::M15, 1, 15), 5);
        // Hour 23
        assert_eq!(time_slot(Granularity::M15, 23, 45), 95);
    }

    #[test]
    fn time_slot_m15_consecutive_minutes_same_slot() {
        // Minutes 0-14 should all be the same slot
        let slot = time_slot(Granularity::M15, 10, 0);
        for m in 0..15 {
            assert_eq!(time_slot(Granularity::M15, 10, m), slot);
        }
        // Minute 15 should be different
        assert_ne!(time_slot(Granularity::M15, 10, 15), slot);
    }

    // --- CandleAccumulator tests ---

    use chrono::TimeZone;

    fn slot_time(h: u32, m: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 5, 1, h, m, 0).unwrap()
    }

    fn candle(time: DateTime<Utc>, close: f64) -> Candle {
        Candle {
            time,
            open: close,
            high: close,
            low: close,
            close,
            volume: 1,
        }
    }

    #[test]
    fn accumulator_returns_none_on_first_tick() {
        let mut acc = CandleAccumulator::new();
        assert!(acc.on_minute_close(10, slot_time(10, 0), 1.2345).is_none());
    }

    #[test]
    fn accumulator_returns_none_within_same_slot() {
        let mut acc = CandleAccumulator::new();
        let t = slot_time(10, 0);
        acc.on_minute_close(10, t, 1.2345);
        assert!(acc.on_minute_close(10, t, 1.2350).is_none());
        assert!(acc.on_minute_close(10, t, 1.2355).is_none());
    }

    #[test]
    fn accumulator_emits_completed_candle_on_slot_change() {
        let mut acc = CandleAccumulator::new();
        let t10 = slot_time(10, 0);
        acc.on_minute_close(10, t10, 1.2345);
        acc.on_minute_close(10, t10, 1.2360);

        let result = acc.on_minute_close(11, slot_time(11, 0), 1.2365).unwrap();
        assert_eq!(result.time, t10);
        assert_eq!(result.open, 1.2345);
        assert_eq!(result.high, 1.2360);
        assert_eq!(result.low, 1.2345);
        assert_eq!(result.close, 1.2360);
        assert_eq!(result.volume, 2);
    }

    #[test]
    fn accumulator_tracks_high_and_low_across_ticks() {
        let mut acc = CandleAccumulator::new();
        let t = slot_time(10, 0);
        acc.on_minute_close(10, t, 1.2345); // open
        acc.on_minute_close(10, t, 1.2400); // new high
        acc.on_minute_close(10, t, 1.2300); // new low
        acc.on_minute_close(10, t, 1.2350); // close

        let result = acc.on_minute_close(11, slot_time(11, 0), 1.2360).unwrap();
        assert_eq!(result.open, 1.2345);
        assert_eq!(result.high, 1.2400);
        assert_eq!(result.low, 1.2300);
        assert_eq!(result.close, 1.2350);
        assert_eq!(result.volume, 4);
    }

    #[test]
    fn accumulator_tracks_multiple_slots() {
        let mut acc = CandleAccumulator::new();
        let t0 = slot_time(0, 0);
        let t1 = slot_time(1, 0);
        let t2 = slot_time(2, 0);

        acc.on_minute_close(0, t0, 1.1000);
        acc.on_minute_close(0, t0, 1.1050);

        let first = acc.on_minute_close(1, t1, 1.2000).unwrap();
        assert_eq!(first.time, t0);
        assert_eq!(first.open, 1.1000);
        assert_eq!(first.close, 1.1050);

        acc.on_minute_close(1, t1, 1.2200);

        let second = acc.on_minute_close(2, t2, 1.3000).unwrap();
        assert_eq!(second.time, t1);
        assert_eq!(second.open, 1.2000);
        assert_eq!(second.close, 1.2200);
    }

    // --- CandleBuffer tests ---

    #[test]
    fn candle_buffer_starts_empty() {
        let buf = CandleBuffer::new(10);
        assert_eq!(buf.candles.len(), 0);
    }

    #[test]
    fn candle_buffer_accumulates_candles() {
        let mut buf = CandleBuffer::new(10);
        buf.push(candle(slot_time(0, 0), 1.0));
        buf.push(candle(slot_time(1, 0), 2.0));
        buf.push(candle(slot_time(2, 0), 3.0));
        assert_eq!(buf.closes(), vec![1.0, 2.0, 3.0]);
    }

    #[test]
    fn candle_buffer_respects_max_size() {
        let mut buf = CandleBuffer::new(3);
        buf.push(candle(slot_time(0, 0), 1.0));
        buf.push(candle(slot_time(1, 0), 2.0));
        buf.push(candle(slot_time(2, 0), 3.0));
        buf.push(candle(slot_time(3, 0), 4.0));
        assert_eq!(buf.closes(), vec![2.0, 3.0, 4.0]);
    }

    #[test]
    fn candle_buffer_evicts_oldest_first() {
        let mut buf = CandleBuffer::new(3);
        for i in 0..10 {
            buf.push(candle(slot_time(i, 0), i as f64));
        }
        assert_eq!(buf.closes(), vec![7.0, 8.0, 9.0]);
    }

    // --- compute_slot_time tests ---

    #[test]
    fn compute_slot_time_h1_returns_start_of_current_hour() {
        let tick = Utc.with_ymd_and_hms(2026, 5, 1, 14, 30, 27).unwrap();
        let expected = Utc.with_ymd_and_hms(2026, 5, 1, 14, 0, 0).unwrap();
        assert_eq!(compute_slot_time(Granularity::H1, tick), expected);
    }

    #[test]
    fn compute_slot_time_m15_returns_start_of_current_15min_block() {
        let tick = Utc.with_ymd_and_hms(2026, 5, 1, 14, 47, 5).unwrap();
        let expected = Utc.with_ymd_and_hms(2026, 5, 1, 14, 45, 0).unwrap();
        assert_eq!(compute_slot_time(Granularity::M15, tick), expected);
    }

    #[test]
    fn compute_slot_time_m15_at_block_boundary() {
        let tick = Utc.with_ymd_and_hms(2026, 5, 1, 14, 0, 0).unwrap();
        let expected = Utc.with_ymd_and_hms(2026, 5, 1, 14, 0, 0).unwrap();
        assert_eq!(compute_slot_time(Granularity::M15, tick), expected);
    }
}
