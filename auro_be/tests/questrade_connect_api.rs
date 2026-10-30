//! `POST /api/questrade/connect`: the checks that answer before any token
//! is sent to Questrade (no test here may reach Questrade: a real exchange
//! would spend a token).

mod common;

use axum::http::{Method, StatusCode};
use common::http::{request, response_json};
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn a_blank_token_is_refused_before_questrade_is_asked() {
    let app = auro::api::live_router().with_state(common::test_state());
    let response = app
        .oneshot(request(
            Method::POST,
            "/api/questrade/connect",
            Some(json!({ "refresh_token": "   " })),
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let body = response_json(response).await;
    assert!(body["error"].as_str().unwrap().contains("empty"));
}

#[tokio::test]
async fn status_says_disconnected_with_no_client() {
    let app = auro::api::live_router().with_state(common::test_state());
    let response = app
        .oneshot(request(Method::GET, "/api/questrade/status", None))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response_json(response).await,
        json!({ "connected": false, "accounts": [] })
    );
}
