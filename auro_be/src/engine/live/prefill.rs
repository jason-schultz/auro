use chrono::{DateTime, Utc};
use sqlx::PgPool;
use std::collections::HashMap;

use crate::engine::rules::Rules;
use crate::engine::types::{
    BufferKey, Candle, CandleBuffer, Direction, Granularity, OpenPosition, StopLossState,
};
use crate::oanda::client::OandaClient;
use crate::state::AppState;

/// Pre-fill the in-memory rules cache from the `rules` table.
/// Closes the gap between Rust startup and Opus's first push (~5min) — without
/// this, Rust would default-enable everything during that window.
pub(crate) async fn run_prefill_rules(state: &AppState) {
    let rows = sqlx::query_as::<_, (uuid::Uuid, bool, Option<String>, DateTime<Utc>)>(
        "SELECT live_strategy_id, enabled, reason, computed_at FROM rules",
    )
    .fetch_all(&state.db)
    .await;

    match rows {
        Ok(rows) => {
            let count = rows.len();
            let cache = Rules::from_db_rows(rows);
            *state.live.rules.write().await = cache;
            tracing::info!("Pre-filled {} rules from database", count);
        }
        Err(e) => {
            tracing::warn!(
                "Failed to pre-fill rules from database: {} — cache stays default-empty (all strategies enabled until first push)",
                e
            );
        }
    }
}

pub(crate) async fn run_prefill_buffers(state: &AppState) {
    match prefill_buffers(state).await {
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
    state: &AppState,
) -> Result<usize, Box<dyn std::error::Error + Send + Sync>> {
    // Get distinct (instrument, granularity) pairs from enabled strategies
    let instruments: Vec<String> =
        sqlx::query_scalar("SELECT DISTINCT instrument FROM live_strategies WHERE enabled = true")
            .fetch_all(&state.db)
            .await?;

    let mut count = 0;

    for instrument in instruments {
        count += load_instrument_buffers(state, &instrument).await?;
    }

    Ok(count)
}

pub(crate) async fn run_prefill_open_positions(state: &AppState) {
    let mut prefetched = HashMap::new();
    match prefill_open_positions(&state.db, &state.oanda, &mut prefetched).await {
        Ok(count) => {
            let mut positions = state.live.open_positions.write().await;
            for (trade_id, position) in prefetched {
                positions.insert(trade_id, position);
            }
            tracing::info!("Pre-filled {} open positions from OANDA", count)
        }
        Err(e) => tracing::error!("Failed to pre-fill open positions: {}", e),
    }
}

async fn prefill_open_positions(
    pool: &PgPool,
    oanda: &OandaClient,
    open_positions: &mut HashMap<String, OpenPosition>,
) -> Result<usize, Box<dyn std::error::Error + Send + Sync>> {
    let oanda_trades = oanda.get_open_trades().await?;
    let trades = oanda_trades["trades"]
        .as_array()
        .ok_or("OANDA get_open_trades did not return a JSON array")?;

    let mut count = 0;
    for trade in trades {
        let trade_id = trade["id"].as_str().ok_or("trade missing id")?;
        let units = trade["currentUnits"].as_str().unwrap_or("0").to_string();

        let row: Option<(
            uuid::Uuid,
            String,
            Direction,
            f64,
            String,
            String,
            Granularity,
        )> = sqlx::query_as(
            "SELECT lt.live_strategy_id, lt.instrument, lt.direction, lt.entry_price, \
            lt.oanda_trade_id, ls.strategy_type, ls.granularity \
            FROM live_trades lt \
            JOIN live_strategies ls ON ls.id = lt.live_strategy_id \
            WHERE lt.oanda_trade_id = $1 AND lt.status = 'open'",
        )
        .bind(trade_id)
        .fetch_optional(pool)
        .await?;

        let Some((
            strategy_id,
            instrument,
            direction,
            entry_price,
            db_trade_id,
            strategy_type,
            granularity,
        )) = row
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
                granularity,
                direction,
                entry_price,
                units,
                stop_loss_state: determine_stop_loss_state(
                    trade,
                    strategy_type.as_str(),
                    entry_price,
                ),
                worst_price: entry_price,
                best_price: entry_price,
            },
        );
        count += 1;
    }

    Ok(count)
}

pub(crate) async fn load_instrument_buffers(
    state: &AppState,
    instrument: &str,
) -> Result<usize, Box<dyn std::error::Error + Send + Sync>> {
    const MTF_GRANULARITIES: &[Granularity] = &[
        Granularity::M1,
        Granularity::M5,
        Granularity::M15,
        Granularity::H1,
        Granularity::H4,
        Granularity::D,
    ];

    let mut built_buffers: Vec<(BufferKey, CandleBuffer)> = Vec::new();

    for granularity in MTF_GRANULARITIES {
        let rows: Vec<(DateTime<Utc>, f64, f64, f64, f64, i32)> = sqlx::query_as(
            r#"
            SELECT timestamp, open, high, low, close, volume
            FROM candles
            WHERE instrument = $1 AND granularity = $2
            ORDER BY timestamp DESC
            LIMIT $3
            "#,
        )
        .bind(instrument)
        .bind(granularity.as_str())
        .bind(granularity.buffer_capacity() as i64)
        .fetch_all(&state.db)
        .await?;

        if rows.is_empty() {
            continue;
        }

        let mut buffer = CandleBuffer::new(granularity.buffer_capacity());

        // Rows come in DESC order (newest first), reverse to get chronological order
        for (time, open, high, low, close, volume) in rows.iter().rev() {
            buffer.push(Candle {
                time: *time,
                open: *open,
                high: *high,
                low: *low,
                close: *close,
                volume: *volume,
            });
        }

        if let Some(last) = buffer.candles.last() {
            buffer.current_mid = last.close;
        }

        tracing::info!(
            "Pre-filled {} {} candles for {}",
            buffer.candles.len(),
            granularity,
            instrument
        );

        built_buffers.push(((instrument.to_string(), *granularity), buffer));
    }

    if built_buffers.is_empty() {
        tracing::warn!("No candle data found for {}, skipping pre-fill", instrument);
        return Ok(0);
    }

    let mut buffers = state.live.buffers.write().await;
    let loaded_count = built_buffers.len();
    for (key, buffer) in built_buffers {
        buffers.insert(key, buffer);
    }

    Ok(loaded_count)
}

fn remove_instrument_entries<T>(map: &mut HashMap<BufferKey, T>, instrument: &str) -> usize {
    let before = map.len();
    map.retain(|(inst, _), _| inst != instrument);
    before - map.len()
}

pub(crate) async fn unload_instrument_buffers(state: &AppState, instrument: &str) -> usize {
    let removed_buffers = {
        let mut buffers = state.live.buffers.write().await;
        remove_instrument_entries(&mut buffers, instrument)
    };

    let removed_accumulators = {
        let mut accumulators = state.live.accumulators.write().await;
        remove_instrument_entries(&mut accumulators, instrument)
    };

    let removed_total = removed_buffers + removed_accumulators;
    tracing::info!(
        "Unloaded {} in-memory entries for {} ({} buffers, {} accumulators)",
        removed_total,
        instrument,
        removed_buffers,
        removed_accumulators
    );

    removed_total
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
    use super::remove_instrument_entries;
    use crate::engine::types::{CandleBuffer, Granularity};
    use std::collections::HashMap;

    #[test]
    fn remove_instrument_entries_removes_only_target_keys() {
        let mut buffers = HashMap::new();
        buffers.insert(
            ("EUR_USD".to_string(), Granularity::H1),
            CandleBuffer::new(200),
        );
        buffers.insert(
            ("EUR_USD".to_string(), Granularity::M15),
            CandleBuffer::new(200),
        );
        buffers.insert(
            ("USD_JPY".to_string(), Granularity::H1),
            CandleBuffer::new(200),
        );

        let removed = remove_instrument_entries(&mut buffers, "EUR_USD");

        assert_eq!(removed, 2);
        assert_eq!(buffers.len(), 1);
        assert!(buffers
            .keys()
            .all(|(instrument, _)| instrument.as_str() == "USD_JPY"));
    }
}
