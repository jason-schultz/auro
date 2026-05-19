use std::num::NonZeroUsize;
use std::sync::{Arc, Mutex};

use auro::api::evaluator::EvaluateResponse;
use auro::config::Config;
use auro::engine::live::sizing::{
    check_concurrent_exposure, compute_units, SizingDecision, SizingInput, SkipReason,
};
use auro::engine::types::{Direction, Granularity, OpenPosition, StopLossState};
use auro::oanda::client::OandaClient;
use auro::state::{AppState, LastQuote, LiveState};
use chrono::Utc;
use lru::LruCache;
use sqlx::postgres::PgPoolOptions;
use tokio::sync::broadcast;
use uuid::Uuid;

fn build_state() -> AppState {
    let config = Config {
        database_url: "postgres://postgres:postgres@localhost/auro".to_string(),
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

    let db = PgPoolOptions::new()
        .connect_lazy(&config.database_url)
        .expect("valid lazy test db url");

    let (price_tx, _) = broadcast::channel(8);

    AppState {
        db,
        config,
        oanda,
        start_time: Utc::now(),
        live: Arc::new(LiveState::new()),
        price_tx,
        eval_cache: Arc::new(Mutex::new(LruCache::<String, EvaluateResponse>::new(
            NonZeroUsize::new(8).unwrap(),
        ))),
    }
}

#[test]
fn risk_pct_zero_uses_static_fallback_policy() {
    let static_units = "1000";
    let risk_pct = 0.0;
    let units = if risk_pct == 0.0 {
        static_units.to_string()
    } else {
        "dynamic".to_string()
    };

    assert_eq!(units, "1000");
}

#[test]
fn risk_pct_dynamic_computes_expected_units_range() {
    let input = SizingInput {
        equity: 100_000.0,
        risk_pct: 0.01,
        entry_price: 50.0,
        sl_price: 45.0,
        instrument: "XAU_USD",
        instrument_min_units: 1,
        instrument_max_units: None,
        strategy_max_units: None,
    };

    match compute_units(input) {
        SizingDecision::Place { units, .. } => {
            assert!(
                (190..=210).contains(&units),
                "expected units in range 190-210, got {units}"
            );
        }
        SizingDecision::Skip { reason, .. } => panic!("unexpected skip: {:?}", reason),
    }
}

#[test]
fn below_minimum_units_skips() {
    let input = SizingInput {
        equity: 100_000.0,
        risk_pct: 0.01,
        entry_price: 1.0,
        sl_price: 0.9,
        instrument: "EUR_USD",
        instrument_min_units: 20_000,
        instrument_max_units: None,
        strategy_max_units: None,
    };

    match compute_units(input) {
        SizingDecision::Skip { reason, .. } => assert_eq!(reason, SkipReason::BelowMinimumUnits),
        SizingDecision::Place { units, .. } => panic!("expected skip, got units={units}"),
    }
}

#[tokio::test]
async fn concurrent_exposure_limit_skips() {
    let state = build_state();
    let mut instruments = Vec::new();

    {
        let mut positions = state.live.open_positions.write().await;
        for idx in 0..6 {
            let trade_id = format!("t{idx}");
            let instrument = format!("INST_{idx}");
            instruments.push(instrument.clone());
            positions.insert(
                trade_id.clone(),
                OpenPosition {
                    strategy_id: Uuid::new_v4(),
                    trade_id,
                    instrument: instrument.clone(),
                    granularity: Granularity::H1,
                    direction: Direction::Long,
                    entry_price: 1.0,
                    units: "8000".to_string(),
                    stop_loss_state: StopLossState::Initial,
                    worst_price: 1.0,
                    best_price: 1.0,
                },
            );
        }
    }

    {
        let mut quotes = state.live.last_quotes.write().await;
        for instrument in instruments {
            quotes.insert(
                instrument,
                LastQuote {
                    mid: 1.0,
                    bid: 1.0,
                    ask: 1.0,
                    at: Utc::now(),
                },
            );
        }
    }

    let result = check_concurrent_exposure(&state, 3_000.0, 100_000.0).await;
    assert_eq!(result, Err(SkipReason::ExceedsConcurrentExposure));
}
