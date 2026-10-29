use sqlx::PgPool;
use std::collections::{HashMap, HashSet};

use crate::brokers::oanda::client::OandaClient;
use crate::db::repositories::{
    candles as candles_repo, live_queries, live_trades as live_trades_repo, rules as rules_repo,
};
use crate::engine::rules::Rules;
use crate::engine::types::{
    BufferKey, CandleBuffer, Direction, Granularity, OpenPosition, StopLossState,
};
use crate::error::{AppError, AppResult};
use crate::state::{AppState, UntrackedTrade};

/// Pre-fill the in-memory rules cache from the `rules` table.
/// Closes the gap between Rust startup and Opus's first push (~5min) — without
/// this, Rust would default-enable everything during that window.
pub(crate) async fn run_prefill_rules(state: &AppState) {
    match rules_repo::load_rules(&state.db).await {
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
async fn prefill_buffers(state: &AppState) -> Result<usize, sqlx::Error> {
    // Keep buffers warm for the full strategy universe, not only currently enabled rows.
    let instruments = live_queries::all_strategy_instruments(&state.db).await?;

    let mut count = 0;

    for instrument in instruments {
        count += load_instrument_buffers(state, &instrument).await?;
    }

    Ok(count)
}

/// Fill `open_positions` from OANDA's open trades at startup. Returns whether
/// it worked; until it has (here or in a later position sync), entries wait.
pub(crate) async fn run_prefill_open_positions(state: &AppState) -> bool {
    match oanda_positions(&state.db, &state.oanda).await {
        Ok(found) => {
            let count = found.tracked.len();
            {
                let mut positions = state.live.open_positions.write().await;
                for (trade_id, position) in found.tracked {
                    positions.insert(trade_id, position);
                }
            }
            *state.live.untracked_trades.write().await = found.untracked;
            *state.live.positions_known.write().await = true;
            tracing::info!("Pre-filled {} open positions from OANDA", count);
            true
        }
        Err(e) => {
            tracing::error!(
                "Failed to pre-fill open positions (entries wait until a sync succeeds): {}",
                e
            );
            false
        }
    }
}

/// What OANDA holds right now, matched to `live_trades` rows.
pub(crate) struct OandaPositions {
    /// Every open trade id at OANDA, tracked or not.
    pub ids: HashSet<String>,
    /// Trades with an open `live_trades` row, as positions.
    pub tracked: HashMap<String, OpenPosition>,
    /// Trades with no row: nothing manages them beyond their stop.
    pub untracked: Vec<UntrackedTrade>,
}

/// OANDA's open trades, matched to their rows. A malformed trade is logged
/// and skipped, never the whole answer.
pub(crate) async fn oanda_positions(
    pool: &PgPool,
    oanda: &OandaClient,
) -> AppResult<OandaPositions> {
    let oanda_trades = oanda.get_open_trades().await?;
    let trades = oanda_trades["trades"]
        .as_array()
        .ok_or_else(|| AppError::Oanda("get_open_trades did not return a trades array".into()))?;

    let mut found = OandaPositions {
        ids: HashSet::new(),
        tracked: HashMap::new(),
        untracked: Vec::new(),
    };
    for trade in trades {
        let (Some(trade_id), Some(units)) = (trade["id"].as_str(), trade["currentUnits"].as_str())
        else {
            tracing::error!(
                "OANDA open trade without an id or units, skipped: {}",
                trade
            );
            continue;
        };
        found.ids.insert(trade_id.to_string());

        let Some(row) =
            live_trades_repo::find_open_trade_with_strategy_by_oanda_id(pool, trade_id).await?
        else {
            found.untracked.push(UntrackedTrade {
                id: trade_id.to_string(),
                instrument: trade["instrument"]
                    .as_str()
                    .unwrap_or("unknown")
                    .to_string(),
                units: units.to_string(),
            });
            continue;
        };

        let (worst_price, best_price) =
            reconstruct_extremes(row.direction, row.entry_price, row.mae_pct, row.mfe_pct);

        found.tracked.insert(
            trade_id.to_string(),
            OpenPosition {
                strategy_id: row.live_strategy_id,
                trade_id: row.oanda_trade_id,
                instrument: row.instrument,
                granularity: row.granularity,
                direction: row.direction,
                entry_price: row.entry_price,
                entry_time: row.entry_time,
                units: units.to_string(),
                stop_loss_state: determine_stop_loss_state(trade, trade_id),
                worst_price,
                best_price,
                strategy_type: row.strategy_type,
            },
        );
    }

    Ok(found)
}

/// Load every granularity's buffer for one instrument from the DB, replacing
/// whatever is in memory. A granularity with no history still gets an empty
/// buffer so the candle feed can fill it.
pub(crate) async fn load_instrument_buffers(
    state: &AppState,
    instrument: &str,
) -> Result<usize, sqlx::Error> {
    let mut built_buffers: Vec<(BufferKey, CandleBuffer)> = Vec::new();

    for granularity in Granularity::ALL {
        let capacity = granularity.buffer_capacity();
        let candles =
            candles_repo::load_recent_candles(&state.db, instrument, *granularity, capacity as i64)
                .await?;

        let mut buffer = CandleBuffer::new(capacity);
        for candle in candles {
            buffer.push(candle);
        }
        tracing::info!(
            "Pre-filled {} {} candles for {}",
            buffer.candles.len(),
            granularity,
            instrument
        );
        built_buffers.push(((instrument.to_string(), *granularity), buffer));
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
    let removed = {
        let mut buffers = state.live.buffers.write().await;
        remove_instrument_entries(&mut buffers, instrument)
    };
    tracing::info!("Unloaded {} buffers for {}", removed, instrument);
    removed
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
    use chrono::{Duration, TimeZone, Utc};

    use super::remove_instrument_entries;
    use crate::db::repositories::candles as candles_repo;
    use crate::engine::live::prefill::load_instrument_buffers;
    use crate::engine::types::{Candle, CandleBuffer, CandleRow, Direction, Granularity, OHLC};
    use crate::state::AppState;
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
    #[ignore = "requires AURO_TEST_DATABASE_URL (migrated test database)"]
    async fn load_instrument_buffers_roundtrips_bid_ask_and_skips_incomplete_rows() {
        let state = AppState::for_tests_with_test_db().await;
        let instrument = "TEST_PREFILL_BID_ASK";
        let ts = Utc.with_ymd_and_hms(2026, 5, 25, 12, 0, 0).unwrap();
        let ohlc = |o, h, l, c| OHLC {
            open: o,
            high: h,
            low: l,
            close: c,
        };

        sqlx::query("DELETE FROM candles WHERE instrument = $1")
            .bind(instrument)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO instruments (symbol, exchange, currency, asset_class, oanda_symbol)
             VALUES ($1, 'OANDA', 'USD', 'fx_cross', $1)
             ON CONFLICT (symbol, exchange) DO NOTHING",
        )
        .bind(instrument)
        .execute(&state.db)
        .await
        .unwrap();

        candles_repo::upsert_candles(
            &state.db,
            &[CandleRow {
                instrument: instrument.to_string(),
                granularity: Granularity::H1,
                candle: Candle {
                    time: ts,
                    mid: ohlc(1.1000, 1.1010, 1.0990, 1.1005),
                    volume: 100,
                    bid: Some(ohlc(1.0999, 1.1009, 1.0989, 1.1004)),
                    ask: Some(ohlc(1.1001, 1.1011, 1.0991, 1.1006)),
                },
            }],
        )
        .await
        .unwrap();

        // A newer in-progress bar left by an older code path must never load.
        sqlx::query(
            "INSERT INTO candles (instrument_id, instrument, granularity, timestamp, open, high, low, close, volume, complete)
             VALUES ((SELECT id FROM instruments WHERE oanda_symbol = $1), $1, 'H1', $2, 9, 9, 9, 9, 1, false)",
        )
        .bind(instrument)
        .bind(ts + Duration::hours(1))
        .execute(&state.db)
        .await
        .unwrap();

        let loaded = load_instrument_buffers(&state, instrument).await.unwrap();
        assert_eq!(loaded, Granularity::ALL.len());

        let buffers = state.live.buffers.read().await;
        let buffer = buffers
            .get(&(instrument.to_string(), Granularity::H1))
            .expect("H1 buffer should be prefilled");
        assert_eq!(buffer.candles.len(), 1, "incomplete bar must be excluded");

        let candle = buffer.candles.last().unwrap();
        assert_eq!(candle.time, ts);
        let bid = candle.bid.as_ref().expect("bid should be populated");
        let ask = candle.ask.as_ref().expect("ask should be populated");
        assert_eq!(
            (bid.open, bid.high, bid.low, bid.close),
            (1.0999, 1.1009, 1.0989, 1.1004)
        );
        assert_eq!(
            (ask.open, ask.high, ask.low, ask.close),
            (1.1001, 1.1011, 1.0991, 1.1006)
        );

        assert!(
            buffers
                .get(&(instrument.to_string(), Granularity::D))
                .is_some_and(|b| b.candles.is_empty()),
            "granularities with no history still get an empty buffer for the feed"
        );
        drop(buffers);

        sqlx::query("DELETE FROM candles WHERE instrument = $1")
            .bind(instrument)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("DELETE FROM instruments WHERE oanda_symbol = $1")
            .bind(instrument)
            .execute(&state.db)
            .await
            .unwrap();
    }
}
