use std::str::FromStr;

use sqlx::PgPool;

use crate::engine::indicators::atr_pct;
use crate::engine::types::Granularity;
use crate::state::AppState;

#[derive(Debug, Clone)]
pub struct RiskParams {
    pub trailing_k: f64,
    pub atr_period: usize,
    pub atr_granularity: Granularity,
    pub exit_confirm_bars: usize,
}

pub async fn get_risk_params(db: &PgPool, instrument: &str, strategy_type: &str) -> RiskParams {
    let row = sqlx::query_as::<_, (f64, i32, String, i32)>(
        r#"SELECT trailing_k, atr_period, atr_granularity, exit_confirm_bars
           FROM instrument_risk_params
           WHERE instrument = $1 AND strategy_type = $2"#,
    )
    .bind(instrument)
    .bind(strategy_type)
    .fetch_optional(db)
    .await;

    match row {
        Ok(Some((trailing_k, atr_period, atr_granularity, exit_confirm_bars))) => {
            let granularity = Granularity::from_str(&atr_granularity).unwrap_or_else(|_| {
                tracing::warn!(
                    "[RISK PARAMS] Invalid atr_granularity={} for {} {}; defaulting to H1",
                    atr_granularity,
                    instrument,
                    strategy_type
                );
                Granularity::H1
            });

            RiskParams {
                trailing_k,
                atr_period: atr_period.max(1) as usize,
                atr_granularity: granularity,
                exit_confirm_bars: exit_confirm_bars.max(1) as usize,
            }
        }
        Ok(None) => {
            tracing::warn!(
                "[RISK PARAMS] Missing instrument_risk_params row for {} {}; using fallback",
                instrument,
                strategy_type
            );
            fallback(strategy_type)
        }
        Err(e) => {
            tracing::warn!(
                "[RISK PARAMS] Lookup failed for {} {}: {}; using fallback",
                instrument,
                strategy_type,
                e
            );
            fallback(strategy_type)
        }
    }
}

pub async fn trailing_distance_price(
    state: &AppState,
    instrument: &str,
    strategy_type: &str,
    current_price: f64,
) -> Option<f64> {
    let params = get_risk_params(&state.db, instrument, strategy_type).await;
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

    Some((atr_pct_value / 100.0) * current_price * params.trailing_k)
}

fn fallback(strategy_type: &str) -> RiskParams {
    let trailing_k = match strategy_type {
        "trend_following" => 2.5,
        "mean_reversion" => {
            tracing::error!(
                "[RISK PARAMS] fallback() called for mean_reversion; check risk-params wiring"
            );
            1.2
        }
        _ => 2.0,
    };

    RiskParams {
        trailing_k,
        atr_period: 14,
        atr_granularity: Granularity::H1,
        exit_confirm_bars: 3,
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
    use crate::engine::types::{Candle, CandleBuffer};
    use crate::oanda::client::OandaClient;
    use crate::state::{AppState, LiveState};

    use super::*;

    fn make_candle(close: f64, idx: i64) -> Candle {
        Candle {
            time: Utc::now() + Duration::hours(idx),
            open: close - 0.0002,
            high: close + 0.0003,
            low: close - 0.0004,
            close,
            volume: 1,
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
            "INSERT INTO instrument_risk_params (instrument, strategy_type, trailing_k, atr_period, atr_granularity, exit_confirm_bars)
             VALUES ($1, $2, $3, $4, $5, $6)",
        )
        .bind("TEST_EUR_USD")
        .bind("trend_following")
        .bind(2.8_f64)
        .bind(21_i32)
        .bind("H1")
        .bind(4_i32)
        .execute(&db)
        .await
        .unwrap();

        let risk = get_risk_params(&db, "TEST_EUR_USD", "trend_following").await;
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

        let risk = get_risk_params(&db, "TEST_MISSING", "trend_following").await;
        assert!((risk.trailing_k - 2.5).abs() < 1e-12);
        assert_eq!(risk.atr_period, 14);
        assert_eq!(risk.atr_granularity, Granularity::H1);
        assert_eq!(risk.exit_confirm_bars, 3);
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
            "INSERT INTO instrument_risk_params (instrument, strategy_type, trailing_k, atr_period, atr_granularity, exit_confirm_bars)
             VALUES ($1, $2, $3, $4, $5, $6)",
        )
        .bind("TEST_GBP_USD")
        .bind("trend_following")
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

        let current_price = candles.last().unwrap().close;
        let atr_pct_value = atr_pct(&candles, 14).unwrap();
        let expected = (atr_pct_value / 100.0) * current_price * 3.0;

        let got = trailing_distance_price(&state, "TEST_GBP_USD", "trend_following", current_price)
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
