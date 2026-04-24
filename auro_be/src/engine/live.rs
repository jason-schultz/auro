use chrono::{Timelike, Utc};
use sqlx::PgPool;
use std::collections::HashMap;
use tokio::sync::broadcast;

use crate::engine::mean_reversion::{self, MRSignal, MeanReversionParams};
use crate::engine::trend_following::{self, TFSignal, TrendFollowingParams};
use crate::engine::types::{
    BufferKey, CandleAccumulator, CandleBuffer, LiveStrategy, OpenPosition,
};
use crate::oanda::client::OandaClient;
use crate::oanda::models::StreamMessage;
use crate::state::{AppState, LastQuote};

/// Calculate the time slot for a given granularity.
/// H1: just the hour (0-23), changes every 60 minutes
/// M15: hour * 4 + (minute / 15), changes every 15 minutes (0-95)
/// M5: hour * 12 + (minute / 5), changes every 5 minutes (0-287)
fn time_slot(granularity: &str, hour: u32, minute: u32) -> u32 {
    match granularity {
        "M5" => hour * 12 + minute / 5,
        "M15" => hour * 4 + minute / 15,
        "H4" => hour / 4,
        "D" => 0,  // daily — only changes on day boundary (handled separately)
        _ => hour, // H1 default
    }
}

pub fn spawn_live_evaluator(mut rx: broadcast::Receiver<StreamMessage>, state: AppState) {
    // let pool = state.db.clone();
    // let oanda = state.oanda.clone();
    tokio::spawn(async move {
        tracing::info!("Live strategy evaluator started (multi-granularity mode)");

        // Pre-fill buffers from the database for all enabled strategies
        run_prefill_buffers(&state).await;

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

                    let tick_time = match chrono::DateTime::parse_from_rfc3339(&price.time) {
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
                        for granularity in &["M15", "H1"] {
                            let key = (instrument.clone(), granularity.to_string());

                            let slot = time_slot(granularity, current_hour, current_minute);

                            let maybe_close = {
                                let mut accumulators = state.live.accumulators.write().await;
                                let accumulator = accumulators
                                    .entry(key.clone())
                                    .or_insert_with(CandleAccumulator::new);
                                accumulator.on_minute_close(slot, mid)
                            };

                            let Some(candle_close) = maybe_close else {
                                continue;
                            };

                            // Candle boundary crossed for this granularity
                            let buffer_snapshot = {
                                let mut buffers = state.live.buffers.write().await;
                                let buffer = buffers
                                    .entry(key.clone())
                                    .or_insert_with(|| CandleBuffer::new(200));
                                buffer.push(candle_close);
                                buffer.current_mid = mid;

                                tracing::debug!(
                                    "{} candle closed for {}: close={:.5}, buffer_len={}",
                                    granularity,
                                    instrument,
                                    candle_close,
                                    buffer.closes.len()
                                );
                                buffer.clone()
                            };

                            {
                                let mut open_positions = state.live.open_positions.write().await;
                                // Evaluate strategies matching this instrument AND granularity
                                if let Err(e) = evaluate_strategies(
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

                    {
                        // Update current_mid on all buffers for this instrument
                        let mut buffers = state.live.buffers.write().await;
                        for granularity in &["M15", "H1"] {
                            let key = (instrument.clone(), granularity.to_string());
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
    let pairs: Vec<(String, String)> = sqlx::query_as(
        "SELECT DISTINCT instrument, granularity FROM live_strategies WHERE enabled = true",
    )
    .fetch_all(pool)
    .await?;

    let mut count = 0;

    for (instrument, granularity) in &pairs {
        let rows: Vec<(f64,)> = sqlx::query_as(
            r#"
            SELECT close
            FROM candles
            WHERE instrument = $1 AND granularity = $2
            ORDER BY timestamp DESC
            LIMIT 200
            "#,
        )
        .bind(instrument)
        .bind(granularity)
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

        let key = (instrument.clone(), granularity.clone());
        let buffer = buffers.entry(key).or_insert_with(|| CandleBuffer::new(200));

        // Rows come in DESC order (newest first), reverse to get chronological order
        for (close,) in rows.iter().rev() {
            buffer.push(*close);
        }

        tracing::info!(
            "Pre-filled {} {} candles for {}",
            buffer.closes.len(),
            granularity,
            instrument
        );

        count += 1;
    }

    Ok(count)
}

async fn is_trading_enabled(pool: &PgPool) -> bool {
    let result: Option<(serde_json::Value,)> =
        sqlx::query_as("SELECT value FROM trading_config WHERE key = 'trading_enabled'")
            .fetch_optional(pool)
            .await
            .unwrap_or(None);

    result
        .and_then(|r| r.0.as_str().map(|s| s == "true"))
        .unwrap_or(false)
}

async fn evaluate_strategies(
    pool: &PgPool,
    oanda: &OandaClient,
    instrument: &str,
    granularity: &str,
    buffer: &CandleBuffer,
    current_price: f64,
    bid: f64,
    ask: f64,
    open_positions: &mut HashMap<uuid::Uuid, OpenPosition>,
) -> Result<(), Box<dyn std::error::Error>> {
    if !is_trading_enabled(pool).await {
        return Ok(());
    }

    // Only fetch strategies matching BOTH instrument and granularity
    let strategies: Vec<LiveStrategy> = sqlx::query_as(
        "SELECT id, strategy_type, instrument, granularity, parameters, enabled, max_position_size \
         FROM live_strategies WHERE instrument = $1 AND granularity = $2 AND enabled = true"
    )
    .bind(instrument)
    .bind(granularity)
    .fetch_all(pool)
    .await?;

    for strategy in &strategies {
        let has_position = open_positions.contains_key(&strategy.id);

        if has_position {
            evaluate_exit(pool, oanda, strategy, current_price, buffer, open_positions).await?;
        } else {
            evaluate_entry(
                pool,
                oanda,
                strategy,
                current_price,
                bid,
                ask,
                buffer,
                open_positions,
            )
            .await?;
        }
    }

    Ok(())
}

async fn evaluate_entry(
    pool: &PgPool,
    oanda: &OandaClient,
    strategy: &LiveStrategy,
    current_price: f64,
    bid: f64,
    ask: f64,
    buffer: &CandleBuffer,
    open_positions: &mut HashMap<uuid::Uuid, OpenPosition>,
) -> Result<(), Box<dyn std::error::Error>> {
    let params = &strategy.parameters;

    match strategy.strategy_type.as_str() {
        "mean_reversion" => {
            let mr_params = MeanReversionParams {
                ma_period: params["ma_period"].as_u64().unwrap_or(20) as usize,
                entry_threshold: params["entry_threshold"].as_f64().unwrap_or(-0.01),
                exit_threshold: params["exit_threshold"].as_f64().unwrap_or(0.003),
                stop_loss: params["stop_loss"].as_f64().unwrap_or(-0.005),
            };

            // Diagnostic: compute MA and deviation for logging
            if buffer.closes.len() >= mr_params.ma_period {
                let ma: f64 = buffer.closes[buffer.closes.len() - mr_params.ma_period..]
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
                    buffer.closes.len(),
                );
            } else {
                tracing::info!(
                    "[STATUS] MR {} {} | buffer {}/{} — waiting for data",
                    strategy.instrument,
                    strategy.granularity,
                    buffer.closes.len(),
                    mr_params.ma_period,
                );
            }

            match mean_reversion::check_entry(&buffer.closes, &mr_params) {
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

                    execute_entry(
                        pool,
                        oanda,
                        strategy,
                        "Long",
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
                    .await?;
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

            // Diagnostic: compute fast/slow MAs for logging
            if buffer.closes.len() >= tf_params.slow_period {
                let fast_ma: f64 = buffer.closes[buffer.closes.len() - tf_params.fast_period..]
                    .iter()
                    .sum::<f64>()
                    / tf_params.fast_period as f64;
                let slow_ma: f64 = buffer.closes[buffer.closes.len() - tf_params.slow_period..]
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
                    buffer.closes.len(),
                );
            } else {
                tracing::info!(
                    "[STATUS] TF {} {} | buffer {}/{} — waiting for data",
                    strategy.instrument,
                    strategy.granularity,
                    buffer.closes.len(),
                    tf_params.slow_period,
                );
            }

            match trend_following::check_entry(&buffer.closes, &tf_params) {
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

                    execute_entry(
                        pool,
                        oanda,
                        strategy,
                        "Long",
                        &strategy.max_position_size,
                        current_price,
                        sl_price,
                        tp_price,
                        &format!("CrossAbove: fast_ma={:.5}, slow_ma={:.5}", fast_ma, slow_ma),
                        open_positions,
                    )
                    .await?;
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

                    execute_entry(
                        pool,
                        oanda,
                        strategy,
                        "Short",
                        &short_units,
                        current_price,
                        sl_price,
                        tp_price,
                        &format!("CrossBelow: fast_ma={:.5}, slow_ma={:.5}", fast_ma, slow_ma),
                        open_positions,
                    )
                    .await?;
                }
                _ => {}
            }
        }
        _ => {}
    }

    Ok(())
}

async fn execute_entry(
    pool: &PgPool,
    oanda: &OandaClient,
    strategy: &LiveStrategy,
    direction: &str,
    units: &str,
    current_price: f64,
    sl_price: f64,
    tp_price: Option<f64>,
    entry_reason: &str,
    open_positions: &mut HashMap<uuid::Uuid, OpenPosition>,
) -> Result<(), Box<dyn std::error::Error>> {
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

            open_positions.insert(
                strategy.id,
                OpenPosition {
                    strategy_id: strategy.id,
                    trade_id,
                    instrument: strategy.instrument.clone(),
                    direction: direction.to_string(),
                    entry_price: fill_price,
                    units: units.to_string(),
                },
            );
        }
        Err(e) => {
            tracing::error!(
                "[ORDER FAILED] {} {} ({}): {}",
                direction,
                strategy.instrument,
                strategy.granularity,
                e
            );
        }
    }

    Ok(())
}

async fn evaluate_exit(
    pool: &PgPool,
    oanda: &OandaClient,
    strategy: &LiveStrategy,
    current_price: f64,
    buffer: &CandleBuffer,
    open_positions: &mut HashMap<uuid::Uuid, OpenPosition>,
) -> Result<(), Box<dyn std::error::Error>> {
    let pos = match open_positions.get(&strategy.id) {
        Some(p) => p,
        None => return Ok(()),
    };

    let params = &strategy.parameters;
    let mut should_exit = false;
    let mut exit_reason = String::new();

    match strategy.strategy_type.as_str() {
        "mean_reversion" => {}
        "trend_following" => {
            let tf_params = TrendFollowingParams {
                fast_period: params["fast_period"].as_u64().unwrap_or(10) as usize,
                slow_period: params["slow_period"].as_u64().unwrap_or(50) as usize,
                stop_loss: params["stop_loss"].as_f64().unwrap_or(-0.02),
                take_profit: params["take_profit"].as_f64(),
            };

            let is_long = pos.direction == "Long";

            match trend_following::check_exit(&buffer.closes, &tf_params, is_long) {
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

    if should_exit {
        let trade_id = pos.trade_id.clone();
        let direction = pos.direction.clone();
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

                let pnl = match direction.as_str() {
                    "Long" => (fill_price - entry_price) / entry_price,
                    "Short" => (entry_price - fill_price) / entry_price,
                    _ => 0.0,
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

                open_positions.remove(&strategy.id);
            }
            Err(e) => {
                tracing::error!("[CLOSE FAILED] {} {}: {}", direction, instrument, e);
            }
        }
    }

    Ok(())
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
        assert_eq!(time_slot("H1", 0, 0), 0);
        assert_eq!(time_slot("H1", 14, 30), 14);
        assert_eq!(time_slot("H1", 23, 59), 23);
    }

    #[test]
    fn time_slot_m15_changes_every_15_minutes() {
        // Hour 0
        assert_eq!(time_slot("M15", 0, 0), 0);
        assert_eq!(time_slot("M15", 0, 14), 0); // still in first 15-min block
        assert_eq!(time_slot("M15", 0, 15), 1); // new block
        assert_eq!(time_slot("M15", 0, 30), 2);
        assert_eq!(time_slot("M15", 0, 45), 3);
        // Hour 1
        assert_eq!(time_slot("M15", 1, 0), 4);
        assert_eq!(time_slot("M15", 1, 15), 5);
        // Hour 23
        assert_eq!(time_slot("M15", 23, 45), 95);
    }

    #[test]
    fn time_slot_m15_consecutive_minutes_same_slot() {
        // Minutes 0-14 should all be the same slot
        let slot = time_slot("M15", 10, 0);
        for m in 0..15 {
            assert_eq!(time_slot("M15", 10, m), slot);
        }
        // Minute 15 should be different
        assert_ne!(time_slot("M15", 10, 15), slot);
    }

    // --- CandleAccumulator tests ---

    #[test]
    fn accumulator_returns_none_on_first_tick() {
        let mut acc = CandleAccumulator::new();
        assert_eq!(acc.on_minute_close(10, 1.2345), None);
    }

    #[test]
    fn accumulator_returns_none_within_same_slot() {
        let mut acc = CandleAccumulator::new();
        acc.on_minute_close(10, 1.2345);
        assert_eq!(acc.on_minute_close(10, 1.2350), None);
        assert_eq!(acc.on_minute_close(10, 1.2355), None);
    }

    #[test]
    fn accumulator_emits_close_on_slot_change() {
        let mut acc = CandleAccumulator::new();
        acc.on_minute_close(10, 1.2345);
        acc.on_minute_close(10, 1.2360); // last_mid = 1.2360

        let result = acc.on_minute_close(11, 1.2365);
        assert_eq!(result, Some(1.2360));
    }

    #[test]
    fn accumulator_tracks_multiple_slots() {
        let mut acc = CandleAccumulator::new();
        acc.on_minute_close(0, 1.1000);
        acc.on_minute_close(0, 1.1050);

        assert_eq!(acc.on_minute_close(1, 1.2000), Some(1.1050));

        acc.on_minute_close(1, 1.2200);

        assert_eq!(acc.on_minute_close(2, 1.3000), Some(1.2200));
    }

    // --- CandleBuffer tests ---

    #[test]
    fn candle_buffer_starts_empty() {
        let buf = CandleBuffer::new(10);
        assert_eq!(buf.closes.len(), 0);
    }

    #[test]
    fn candle_buffer_accumulates_closes() {
        let mut buf = CandleBuffer::new(10);
        buf.push(1.0);
        buf.push(2.0);
        buf.push(3.0);
        assert_eq!(buf.closes, vec![1.0, 2.0, 3.0]);
    }

    #[test]
    fn candle_buffer_respects_max_size() {
        let mut buf = CandleBuffer::new(3);
        buf.push(1.0);
        buf.push(2.0);
        buf.push(3.0);
        buf.push(4.0);
        assert_eq!(buf.closes, vec![2.0, 3.0, 4.0]);
    }

    #[test]
    fn candle_buffer_evicts_oldest_first() {
        let mut buf = CandleBuffer::new(3);
        for i in 0..10 {
            buf.push(i as f64);
        }
        assert_eq!(buf.closes, vec![7.0, 8.0, 9.0]);
    }
}
