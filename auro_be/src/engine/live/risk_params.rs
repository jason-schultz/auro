use std::str::FromStr;

use sqlx::PgPool;

use crate::db::repositories::risk_params as risk_params_repo;
use crate::engine::indicators::atr_pct;
use crate::engine::risk_defaults::{default_exit_confirm_bars, default_trailing_k};
use crate::engine::types::Granularity;
use crate::state::AppState;

#[derive(Debug, Clone)]
pub struct RiskParams {
    pub trailing_k: f64,
    pub atr_period: usize,
    pub atr_granularity: Granularity,
    pub exit_confirm_bars: usize,
}

pub async fn get_risk_params(
    db: &PgPool,
    instrument: &str,
    strategy_type: &str,
    strategy_granularity: Granularity,
) -> RiskParams {
    let row = risk_params_repo::find_instrument_risk_params(
        db,
        instrument,
        strategy_type,
        strategy_granularity.as_str(),
    )
    .await;

    match row {
        Ok(Some(row)) => {
            let atr_granularity_parsed = Granularity::from_str(&row.atr_granularity)
                .unwrap_or_else(|_| {
                    tracing::warn!(
                        "[RISK PARAMS] Invalid atr_granularity={} for {} {} {}; defaulting to H1",
                        row.atr_granularity,
                        instrument,
                        strategy_type,
                        strategy_granularity
                    );
                    Granularity::H1
                });

            RiskParams {
                trailing_k: row.trailing_k,
                atr_period: row.atr_period.max(1) as usize,
                atr_granularity: atr_granularity_parsed,
                exit_confirm_bars: row.exit_confirm_bars.max(1) as usize,
            }
        }
        Ok(None) => {
            tracing::info!(
                "[RISK PARAMS] No row for {} {} {}; using granularity-aware fallback",
                instrument,
                strategy_type,
                strategy_granularity
            );
            fallback(strategy_type, strategy_granularity)
        }
        Err(e) => {
            tracing::warn!(
                "[RISK PARAMS] Lookup failed for {} {} {}: {}; using fallback",
                instrument,
                strategy_type,
                strategy_granularity,
                e
            );
            fallback(strategy_type, strategy_granularity)
        }
    }
}

pub async fn trailing_distance_price(
    state: &AppState,
    instrument: &str,
    strategy_type: &str,
    strategy_granularity: Granularity,
    current_price: f64,
    trailing_k_override: Option<f64>,
) -> Option<f64> {
    let params = get_risk_params(&state.db, instrument, strategy_type, strategy_granularity).await;
    let key = (instrument.to_string(), params.atr_granularity);

    let candles = {
        let buffers = state.live.buffers.read().await;
        buffers.get(&key).map(|b| b.candles.clone())
    };

    let Some(candles) = candles else {
        tracing::warn!(
            "[RISK PARAMS] Missing {} buffer for {} while computing trailing distance",
            params.atr_granularity,
            instrument
        );
        return None;
    };

    let Some(atr_pct_value) = atr_pct(&candles, params.atr_period) else {
        tracing::warn!(
            "[RISK PARAMS] Not enough {} candles for {} period={} while computing trailing distance",
            params.atr_granularity,
            instrument,
            params.atr_period
        );
        return None;
    };

    let effective_trailing_k = trailing_k_override.unwrap_or(params.trailing_k);
    let raw_distance = (atr_pct_value / 100.0) * current_price * effective_trailing_k;

    let (min_trail, max_trail) = {
        let meta = state.live.instrument_metadata.read().await;
        let m = meta.get(instrument);
        (
            m.and_then(|m| m.minimum_trailing_stop_distance),
            m.and_then(|m| m.maximum_trailing_stop_distance),
        )
    };

    let clamped = clamp_trailing_distance(raw_distance, min_trail, max_trail);

    if (clamped - raw_distance).abs() / raw_distance.max(1e-9) > 0.10 {
        tracing::warn!(
            "[TRAIL CLAMP] {} {} raw={:.6} clamped={:.6} ({:.0}% change) — strategy params may not fit instrument volatility",
            instrument,
            strategy_type,
            raw_distance,
            clamped,
            ((clamped - raw_distance) / raw_distance.max(1e-9) * 100.0).abs()
        );
    }

    Some(clamped)
}

fn clamp_trailing_distance(
    raw_distance: f64,
    min_trail: Option<f64>,
    max_trail: Option<f64>,
) -> f64 {
    let mut clamped = raw_distance;
    if let Some(max) = max_trail {
        clamped = clamped.min(max);
    }
    if let Some(min) = min_trail {
        clamped = clamped.max(min);
    }
    clamped
}

fn fallback(strategy_type: &str, strategy_granularity: Granularity) -> RiskParams {
    RiskParams {
        trailing_k: default_trailing_k(strategy_type),
        atr_period: 14,
        atr_granularity: Granularity::H1,
        exit_confirm_bars: default_exit_confirm_bars(strategy_granularity),
    }
}

#[cfg(test)]
mod tests {
    use std::num::NonZeroUsize;
    use std::sync::{Arc, Mutex};

    use chrono::{Duration, Utc};
    use lru::LruCache;
    use tokio::sync::broadcast;

    use crate::config::Config;
    use crate::engine::indicators::atr_pct;
    use crate::engine::types::{Candle, CandleBuffer, OHLC};
    use crate::oanda::client::OandaClient;
    use crate::state::{AppState, LiveState};

    use super::*;

    #[test]
    fn clamp_trailing_distance_applies_min_and_max_bounds() {
        let max_clamped = clamp_trailing_distance(1.5, Some(0.5), Some(1.0));
        let min_clamped = clamp_trailing_distance(0.2, Some(0.5), Some(1.0));

        assert!((max_clamped - 1.0).abs() < 1e-12);
        assert!((min_clamped - 0.5).abs() < 1e-12);
    }

    fn make_candle(close: f64, idx: i64) -> Candle {
        Candle {
            time: Utc::now() + Duration::hours(idx),
            mid: OHLC {
                open: close - 0.0002,
                high: close + 0.0003,
                low: close - 0.0004,
                close,
            },
            volume: 1,
            bid: None,
            ask: None,
        }
    }

    fn make_state(db: PgPool) -> AppState {
        let config = Config {
            database_url: "postgres://unused".to_string(),
            oanda_api_key: "test-key".to_string(),
            oanda_account_id: "test-account".to_string(),
            oanda_base_url: "http://127.0.0.1:1".to_string(),
            oanda_stream_url: "http://127.0.0.1:1".to_string(),
            host: "127.0.0.1".to_string(),
            port: 0,
        };

        let oanda = OandaClient::new(
            &config.oanda_base_url,
            &config.oanda_stream_url,
            &config.oanda_api_key,
            &config.oanda_account_id,
        );

        let (price_tx, _) = broadcast::channel(8);

        AppState {
            db,
            config,
            oanda,
            start_time: Utc::now(),
            live: Arc::new(LiveState::new()),
            price_tx,
            eval_cache: Arc::new(Mutex::new(LruCache::new(NonZeroUsize::new(16).unwrap()))),
        }
    }

    async fn test_db_pool() -> PgPool {
        let db_url = std::env::var("AURO_TEST_DATABASE_URL")
            .expect("AURO_TEST_DATABASE_URL must be set for DB-backed risk_params tests");
        PgPool::connect(&db_url)
            .await
            .expect("failed connecting to AURO_TEST_DATABASE_URL")
    }

    #[tokio::test]
    #[ignore = "requires AURO_TEST_DATABASE_URL and migrated test DB"]
    async fn get_risk_params_returns_row_when_present() {
        let db = test_db_pool().await;

        sqlx::query(
            "DELETE FROM instrument_risk_params WHERE instrument = $1 AND strategy_type = $2",
        )
        .bind("TEST_EUR_USD")
        .bind("trend_following")
        .execute(&db)
        .await
        .unwrap();

        sqlx::query(
            "INSERT INTO instrument_risk_params (instrument, strategy_type, granularity, trailing_k, atr_period, atr_granularity, exit_confirm_bars)
             VALUES ($1, $2, $3, $4, $5, $6, $7)",
        )
        .bind("TEST_EUR_USD")
        .bind("trend_following")
        .bind("H1")
        .bind(2.8_f64)
        .bind(21_i32)
        .bind("H1")
        .bind(4_i32)
        .execute(&db)
        .await
        .unwrap();

        let risk = get_risk_params(&db, "TEST_EUR_USD", "trend_following", Granularity::H1).await;
        assert!((risk.trailing_k - 2.8).abs() < 1e-12);
        assert_eq!(risk.atr_period, 21);
        assert_eq!(risk.atr_granularity, Granularity::H1);
        assert_eq!(risk.exit_confirm_bars, 4);
    }

    #[tokio::test]
    #[ignore = "requires AURO_TEST_DATABASE_URL and migrated test DB"]
    async fn get_risk_params_missing_row_uses_fallback_values() {
        let db = test_db_pool().await;

        sqlx::query(
            "DELETE FROM instrument_risk_params WHERE instrument = $1 AND strategy_type = $2",
        )
        .bind("TEST_MISSING")
        .bind("trend_following")
        .execute(&db)
        .await
        .unwrap();

        // H4 fallback: exit_confirm_bars=3 (unchanged from prior defaults)
        let risk_h4 =
            get_risk_params(&db, "TEST_MISSING", "trend_following", Granularity::H4).await;
        assert!((risk_h4.trailing_k - 2.5).abs() < 1e-12);
        assert_eq!(risk_h4.atr_period, 14);
        assert_eq!(risk_h4.atr_granularity, Granularity::H1);
        assert_eq!(risk_h4.exit_confirm_bars, 3);

        // M5 fallback: exit_confirm_bars=24 (~2h confirmation, vs. old broken 3-bar = 15min)
        let risk_m5 =
            get_risk_params(&db, "TEST_MISSING", "trend_following", Granularity::M5).await;
        assert_eq!(risk_m5.exit_confirm_bars, 24);
    }

    #[tokio::test]
    #[ignore = "requires AURO_TEST_DATABASE_URL and migrated test DB"]
    async fn trailing_distance_price_uses_atr_times_k() {
        let db = test_db_pool().await;

        sqlx::query(
            "DELETE FROM instrument_risk_params WHERE instrument = $1 AND strategy_type = $2",
        )
        .bind("TEST_GBP_USD")
        .bind("trend_following")
        .execute(&db)
        .await
        .unwrap();

        sqlx::query(
            "INSERT INTO instrument_risk_params (instrument, strategy_type, granularity, trailing_k, atr_period, atr_granularity, exit_confirm_bars)
             VALUES ($1, $2, $3, $4, $5, $6, $7)",
        )
        .bind("TEST_GBP_USD")
        .bind("trend_following")
        .bind("H1")
        .bind(3.0_f64)
        .bind(14_i32)
        .bind("H1")
        .bind(3_i32)
        .execute(&db)
        .await
        .unwrap();

        let state = make_state(db.clone());

        let mut buffer = CandleBuffer::new(64);
        for i in 0..40 {
            let close = 1.2000 + (i as f64 * 0.0005);
            buffer.push(make_candle(close, i));
        }
        let candles = buffer.candles.clone();

        {
            let mut buffers = state.live.buffers.write().await;
            buffers.insert(("TEST_GBP_USD".to_string(), Granularity::H1), buffer);
        }

        let current_price = candles.last().unwrap().mid.close;
        let atr_pct_value = atr_pct(&candles, 14).unwrap();
        let expected = (atr_pct_value / 100.0) * current_price * 3.0;

        let got = trailing_distance_price(
            &state,
            "TEST_GBP_USD",
            "trend_following",
            Granularity::H1,
            current_price,
            None,
        )
        .await
        .unwrap();

        assert!(
            (got - expected).abs() < 1e-12,
            "expected {}, got {}",
            expected,
            got
        );
    }
}
