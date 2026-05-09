mod common;

use auro::api;
use auro::api::evaluator::EvaluateResponse;
use axum::http::{Method, StatusCode};
use chrono::{TimeZone, Utc};
use tower::util::ServiceExt;

#[tokio::test]
async fn evaluate_endpoint_returns_cached_response_as_duplicate() {
    let state = common::test_state();
    let target_slot = Utc.with_ymd_and_hms(2026, 5, 8, 12, 0, 0).unwrap();
    let idempotency_key = "idem-123".to_string();

    {
        let mut cache = state.eval_cache.lock().unwrap();
        cache.put(
            idempotency_key.clone(),
            EvaluateResponse {
                evaluated: true,
                target_slot,
                data_slot: Some(target_slot),
                staleness_candles: 0,
                duplicate: false,
                signals: vec![],
                reason: Some("seeded".to_string()),
            },
        );
    }

    let app = api::router().with_state(state.clone());
    let request_body = serde_json::json!({
        "target_slot": target_slot.to_rfc3339(),
        "idempotency_key": idempotency_key,
    });

    let request = common::http::request(Method::POST, "/api/evaluate/H1", Some(request_body));
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let payload = common::http::response_json(response).await;
    assert_eq!(payload["duplicate"], serde_json::json!(true));
    assert_eq!(payload["evaluated"], serde_json::json!(true));
    assert_eq!(payload["staleness_candles"], serde_json::json!(0));
    assert_eq!(payload["reason"], serde_json::json!("seeded"));
}

#[tokio::test]
async fn evaluate_endpoint_rejects_invalid_granularity() {
    let state = common::test_state();
    let target_slot = Utc.with_ymd_and_hms(2026, 5, 8, 12, 0, 0).unwrap();
    let app = api::router().with_state(state);

    let request_body = serde_json::json!({
        "target_slot": target_slot.to_rfc3339(),
        "idempotency_key": "idem-invalid-granularity",
    });

    let request = common::http::request(Method::POST, "/api/evaluate/NOT_A_REAL_GRANULARITY", Some(request_body));
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let payload = common::http::response_json(response).await;
    let error = payload["error"].as_str().unwrap_or_default();
    assert!(error.contains("invalid granularity"));
}

#[tokio::test]
async fn evaluate_endpoint_rejects_malformed_json_body() {
    let state = common::test_state();
    let app = api::router().with_state(state.clone());
    let key = "idem-malformed";

    let request = common::http::request(
        Method::POST,
        "/api/evaluate/H1",
        Some(serde_json::json!({
            "target_slot": 123,
            "idempotency_key": key,
        })),
    );
    let response = app.oneshot(request).await.unwrap();

    assert!(
        response.status() == StatusCode::BAD_REQUEST
            || response.status() == StatusCode::UNPROCESSABLE_ENTITY
    );

    let mut cache = state.eval_cache.lock().unwrap();
    assert!(
        cache.get(key).is_none(),
        "malformed requests must not be cached"
    );
}

#[tokio::test]
async fn evaluate_endpoint_rejects_missing_idempotency_key() {
    let state = common::test_state();
    let app = api::router().with_state(state);

    let request = common::http::request(
        Method::POST,
        "/api/evaluate/H1",
        Some(serde_json::json!({
            "target_slot": Utc
                .with_ymd_and_hms(2026, 5, 8, 12, 0, 0)
                .unwrap()
                .to_rfc3339(),
        })),
    );
    let response = app.oneshot(request).await.unwrap();

    assert!(
        response.status() == StatusCode::BAD_REQUEST
            || response.status() == StatusCode::UNPROCESSABLE_ENTITY
    );
}

#[tokio::test]
async fn evaluate_endpoint_rejects_missing_target_slot() {
    let state = common::test_state();
    let app = api::router().with_state(state);

    let request = common::http::request(
        Method::POST,
        "/api/evaluate/H1",
        Some(serde_json::json!({
            "idempotency_key": "idem-missing-target",
        })),
    );
    let response = app.oneshot(request).await.unwrap();

    assert!(
        response.status() == StatusCode::BAD_REQUEST
            || response.status() == StatusCode::UNPROCESSABLE_ENTITY
    );
}

#[tokio::test]
async fn evaluate_endpoint_idempotency_replays_after_successful_non_cached_call() {
    let state = common::test_state();
    let app = api::router().with_state(state);
    let target_slot = Utc.with_ymd_and_hms(2026, 5, 8, 15, 0, 0).unwrap();
    let key = "idem-replay";

    let request1 = common::http::request(
        Method::POST,
        "/api/evaluate/H1",
        Some(serde_json::json!({
            "target_slot": target_slot.to_rfc3339(),
            "idempotency_key": key,
        })),
    );
    let response1 = app.clone().oneshot(request1).await.unwrap();
    assert_eq!(response1.status(), StatusCode::OK);
    let payload1 = common::http::response_json(response1).await;
    assert_eq!(payload1["duplicate"], serde_json::json!(false));
    assert_eq!(payload1["reason"], serde_json::json!("trading_disabled"));

    let request2 = common::http::request(
        Method::POST,
        "/api/evaluate/H1",
        Some(serde_json::json!({
            "target_slot": target_slot.to_rfc3339(),
            "idempotency_key": key,
        })),
    );
    let response2 = app.oneshot(request2).await.unwrap();
    assert_eq!(response2.status(), StatusCode::OK);
    let payload2 = common::http::response_json(response2).await;
    assert_eq!(payload2["duplicate"], serde_json::json!(true));
    assert_eq!(payload2["reason"], serde_json::json!("trading_disabled"));
}
