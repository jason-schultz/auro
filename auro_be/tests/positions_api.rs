mod common;

use auro::api;
use auro::engine::types::{Direction, Granularity, OpenPosition, StopLossState};
use axum::http::{Method, StatusCode};
use futures_util::future::join_all;
use tower::util::ServiceExt;

fn sample_position(trade_id: &str) -> OpenPosition {
    OpenPosition {
        strategy_id: uuid::Uuid::nil(),
        trade_id: trade_id.to_string(),
        instrument: "EUR_USD".to_string(),
        direction: Direction::Long,
        entry_price: 1.12345,
        units: "1000".to_string(),
        stop_loss_state: StopLossState::Initial,
        granularity: Granularity::H1,
    }
}

#[tokio::test]
async fn delete_position_endpoint_removes_existing_position() {
    let state = common::test_state();
    {
        let mut positions = state.live.open_positions.write().await;
        positions.insert("trade-1".to_string(), sample_position("trade-1"));
    }

    let app = api::router().with_state(state.clone());
    let request = common::http::request(Method::DELETE, "/api/positions/trade-1", None);
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let payload = common::http::response_json(response).await;
    assert_eq!(payload, serde_json::json!({"removed": true}));

    let positions = state.live.open_positions.read().await;
    assert!(!positions.contains_key("trade-1"));
}

#[tokio::test]
async fn delete_position_endpoint_is_noop_for_unknown_trade_id() {
    let state = common::test_state();
    let app = api::router().with_state(state.clone());
    let request = common::http::request(Method::DELETE, "/api/positions/missing", None);

    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let payload = common::http::response_json(response).await;
    assert_eq!(payload, serde_json::json!({"removed": false}));
}

#[tokio::test]
async fn delete_position_endpoint_handles_parallel_removals() {
    let state = common::test_state();
    let n = 32usize;

    {
        let mut positions = state.live.open_positions.write().await;
        for i in 0..n {
            let trade_id = format!("trade-{}", i);
            positions.insert(trade_id.clone(), sample_position(&trade_id));
        }
    }

    let app = api::router().with_state(state.clone());

    let futures = (0..n).map(|i| {
        let app = app.clone();
        async move {
            let uri = format!("/api/positions/trade-{}", i);
            let request = common::http::request(Method::DELETE, &uri, None);
            let response = app.oneshot(request).await.unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let payload = common::http::response_json(response).await;
            assert_eq!(payload, serde_json::json!({"removed": true}));
        }
    });

    join_all(futures).await;

    let positions = state.live.open_positions.read().await;
    assert!(positions.is_empty());
}
