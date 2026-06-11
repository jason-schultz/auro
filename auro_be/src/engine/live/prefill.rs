use chrono::{DateTime, Utc};
use sqlx::PgPool;
use std::collections::HashMap;

use crate::brokers::oanda::client::OandaClient;
use crate::db::repositories::{live_queries, live_trades as live_trades_repo};
use crate::engine::rules::Rules;
use crate::engine::types::{
    BufferKey, Candle, CandleBuffer, Direction, Granularity, OpenPosition, StopLossState, OHLC,
};
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

/// Pre-fill candle buffers from the database for all strategy rows.
/// Loads up to each granularity's `buffer_capacity()` per
/// (instrument, granularity) pair.
async fn prefill_buffers(
    state: &AppState,
) -> Result<usize, Box<dyn std::error::Error + Send + Sync>> {
    // Keep buffers warm for the full strategy universe, not only currently enabled rows.
    let instruments = live_queries::all_strategy_instruments(&state.db).await?;

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

        let row =
            live_trades_repo::find_open_trade_with_strategy_by_oanda_id(pool, trade_id).await?;

        let Some(row) = row else {
            tracing::warn!(
                "OANDA has open trade {} but no matching live_trades row — skipping",
                trade_id
            );
            continue;
        };

        let (worst_price, best_price) =
            reconstruct_extremes(row.direction, row.entry_price, row.mae_pct, row.mfe_pct);

        open_positions.insert(
            trade_id.to_string(),
            OpenPosition {
                strategy_id: row.live_strategy_id,
                trade_id: row.oanda_trade_id,
                instrument: row.instrument,
                granularity: row.granularity,
                direction: row.direction,
                entry_price: row.entry_price,
                entry_time: row.entry_time,
                units,
                stop_loss_state: determine_stop_loss_state(trade, trade_id),
                worst_price,
                best_price,
                strategy_type: row.strategy_type,
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
    let mut built_buffers: Vec<(BufferKey, CandleBuffer)> = Vec::new();

    #[allow(clippy::type_complexity)]
    for granularity in Granularity::ALL {
        let rows: Vec<(
            DateTime<Utc>,
            f64,
            f64,
            f64,
            f64,
            i32,
            Option<f64>,
            Option<f64>,
            Option<f64>,
            Option<f64>,
            Option<f64>,
            Option<f64>,
            Option<f64>,
            Option<f64>,
        )> = sqlx::query_as(
            r#"
            SELECT
                timestamp,
                open,
                high,
                low,
                close,
                volume,
                bid_open,
                bid_high,
                bid_low,
                bid_close,
                ask_open,
                ask_high,
                ask_low,
                ask_close
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
        for (
            time,
            open,
            high,
            low,
            close,
            volume,
            bid_open,
            bid_high,
            bid_low,
            bid_close,
            ask_open,
            ask_high,
            ask_low,
            ask_close,
        ) in rows.iter().rev()
        {
            let bid = match (bid_open, bid_high, bid_low, bid_close) {
                (Some(open), Some(high), Some(low), Some(close)) => Some(OHLC {
                    open: *open,
                    high: *high,
                    low: *low,
                    close: *close,
                }),
                _ => None,
            };

            let ask = match (ask_open, ask_high, ask_low, ask_close) {
                (Some(open), Some(high), Some(low), Some(close)) => Some(OHLC {
                    open: *open,
                    high: *high,
                    low: *low,
                    close: *close,
                }),
                _ => None,
            };

            buffer.push(Candle {
                time: *time,
                mid: OHLC {
                    open: *open,
                    high: *high,
                    low: *low,
                    close: *close,
                },
                volume: *volume,
                bid,
                ask,
            });
        }

        if let Some(last) = buffer.candles.last() {
            buffer.current_mid = last.mid.close;
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

fn determine_stop_loss_state(trade: &serde_json::Value, trade_id: &str) -> StopLossState {
    if trade.get("trailingStopLossOrder").is_some() {
        return StopLossState::Trailing;
    }

    // Fixed SL/TP at OANDA is the normal shape for non-trailing trades.
    // Only an entirely unprotected trade is worth a warning.
    if trade.get("stopLossOrder").is_none() {
        tracing::warn!("open trade {} has no stop loss order", trade_id);
    }

    StopLossState::NotApplicable
}

fn reconstruct_extremes(
    direction: Direction,
    entry_price: f64,
    mae_pct: Option<f64>,
    mfe_pct: Option<f64>,
) -> (f64, f64) {
    let mae = mae_pct.unwrap_or(0.0).max(0.0);
    let mfe = mfe_pct.unwrap_or(0.0).max(0.0);

    match direction {
        Direction::Long => (entry_price * (1.0 - mae), entry_price * (1.0 + mfe)),
        Direction::Short => (entry_price * (1.0 + mae), entry_price * (1.0 - mfe)),
    }
}

#[cfg(test)]
mod tests {
    use std::num::NonZeroUsize;
    use std::sync::{Arc, Mutex};

    use chrono::{TimeZone, Utc};
    use lru::LruCache;
    use sqlx::PgPool;
    use tokio::sync::broadcast;

    use super::remove_instrument_entries;
    use crate::brokers::oanda::client::OandaClient;
    use crate::brokers::wealthsimple::client::WealthsimpleClient;
    use crate::config::Config;
    use crate::engine::live::prefill::load_instrument_buffers;
    use crate::engine::types::{CandleBuffer, Direction, Granularity};
    use crate::state::{AppState, LiveState};
    use std::collections::HashMap;

    fn make_state(db: PgPool) -> AppState {
        let config = Config {
            database_url: "postgres://unused".to_string(),
            oanda_api_key: "test-key".to_string(),
            oanda_account_id: "test-account".to_string(),
            oanda_base_url: "http://127.0.0.1:1".to_string(),
            oanda_stream_url: "http://127.0.0.1:1".to_string(),
            host: "127.0.0.1".to_string(),
            port: 0,
            questrade_refresh_token: None,
        };

        let oanda = OandaClient::new(
            &config.oanda_base_url,
            &config.oanda_stream_url,
            &config.oanda_api_key,
            &config.oanda_account_id,
        );

        let (price_tx, _) = broadcast::channel(8);
        let wealthsimple = WealthsimpleClient::new(&db);

        AppState {
            db,
            config,
            oanda,
            start_time: Utc::now(),
            live: Arc::new(LiveState::new()),
            price_tx,
            eval_cache: Arc::new(Mutex::new(LruCache::new(NonZeroUsize::new(16).unwrap()))),
            questrade: None,
            wealthsimple,
        }
    }

    async fn test_db_pool() -> PgPool {
        let db_url = std::env::var("AURO_TEST_DATABASE_URL")
            .expect("AURO_TEST_DATABASE_URL must be set for DB-backed prefill tests");
        PgPool::connect(&db_url)
            .await
            .expect("failed connecting to AURO_TEST_DATABASE_URL")
    }

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

    #[test]
    fn reconstruct_extremes_long_uses_mae_mfe_magnitudes() {
        let (worst, best) =
            super::reconstruct_extremes(Direction::Long, 100.0, Some(0.1), Some(0.2));
        assert!((worst - 90.0).abs() < 1e-9);
        assert!((best - 120.0).abs() < 1e-9);
    }

    #[test]
    fn reconstruct_extremes_short_uses_mae_mfe_magnitudes() {
        let (worst, best) =
            super::reconstruct_extremes(Direction::Short, 100.0, Some(0.1), Some(0.2));
        assert!((worst - 110.0).abs() < 1e-9);
        assert!((best - 80.0).abs() < 1e-9);
    }

    #[tokio::test]
    #[ignore = "requires AURO_TEST_DATABASE_URL and migrated test DB"]
    async fn load_instrument_buffers_roundtrips_bid_ask_from_db() {
        let db = test_db_pool().await;
        let state = make_state(db.clone());

        let instrument = "TEST_PREFILL_BID_ASK";
        let ts = Utc.with_ymd_and_hms(2026, 5, 25, 12, 0, 0).unwrap();

        sqlx::query("DELETE FROM candles WHERE instrument = $1 AND granularity = 'H1'")
            .bind(instrument)
            .execute(&db)
            .await
            .unwrap();

        sqlx::query(
            r#"
            INSERT INTO candles (
                instrument,
                granularity,
                timestamp,
                open,
                high,
                low,
                close,
                volume,
                complete,
                bid_open,
                bid_high,
                bid_low,
                bid_close,
                ask_open,
                ask_high,
                ask_low,
                ask_close
            ) VALUES (
                $1, 'H1', $2,
                1.1000, 1.1010, 1.0990, 1.1005,
                100, true,
                1.0999, 1.1009, 1.0989, 1.1004,
                1.1001, 1.1011, 1.0991, 1.1006
            )
            "#,
        )
        .bind(instrument)
        .bind(ts)
        .execute(&db)
        .await
        .unwrap();

        let loaded = load_instrument_buffers(&state, instrument).await.unwrap();
        assert!(loaded >= 1);

        let buffers = state.live.buffers.read().await;
        let key = (instrument.to_string(), Granularity::H1);
        let buffer = buffers.get(&key).expect("H1 buffer should be prefilled");
        assert!(!buffer.candles.is_empty());

        let candle = buffer.candles.last().unwrap();
        let bid = candle.bid.as_ref().expect("bid should be populated");
        let ask = candle.ask.as_ref().expect("ask should be populated");

        assert_eq!(bid.open, 1.0999);
        assert_eq!(bid.high, 1.1009);
        assert_eq!(bid.low, 1.0989);
        assert_eq!(bid.close, 1.1004);
        assert_eq!(ask.open, 1.1001);
        assert_eq!(ask.high, 1.1011);
        assert_eq!(ask.low, 1.0991);
        assert_eq!(ask.close, 1.1006);

        drop(buffers);

        sqlx::query("DELETE FROM candles WHERE instrument = $1 AND granularity = 'H1'")
            .bind(instrument)
            .execute(&db)
            .await
            .unwrap();
    }
}
