mod common;

use auro::api;
use auro::engine::rules::{RuleEntry, RulesPayload};
use axum::http::{Method, StatusCode};
use chrono::{TimeZone, Utc};
use std::collections::HashMap;
use tower::util::ServiceExt;
use uuid::Uuid;

#[tokio::test]
async fn push_rules_applies_payload_and_returns_counts() {
    let state = common::test_state();
    let app = api::router().with_state(state.clone());

    let strategy_a = Uuid::new_v4();
    let strategy_b = Uuid::new_v4();
    let computed_at = Utc.with_ymd_and_hms(2026, 5, 8, 10, 0, 0).unwrap();

    let body = serde_json::json!({
        "rules": {
            strategy_a.to_string(): { "enabled": true, "reason": "trending" },
            strategy_b.to_string(): { "enabled": false, "reason": "choppy" }
        },
        "computed_at": computed_at.to_rfc3339(),
    });

    let request = common::http::request(Method::POST, "/api/rules", Some(body));
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let payload = common::http::response_json(response).await;
    assert_eq!(
        payload,
        serde_json::json!({
            "applied": true,
            "enabled": 1,
            "disabled": 1,
        })
    );

    let rules = state.live.rules.read().await;
    assert_eq!(rules.decision(&strategy_a), (true, Some("trending")));
    assert_eq!(rules.decision(&strategy_b), (false, Some("choppy")));
    assert_eq!(rules.computed_at, Some(computed_at));
}

#[tokio::test]
async fn push_rules_replaces_prior_snapshot() {
    let state = common::test_state();

    let old_id = Uuid::new_v4();
    let mut old_map = HashMap::new();
    old_map.insert(
        old_id,
        RuleEntry {
            enabled: false,
            reason: "old".to_string(),
        },
    );

    {
        let mut rules = state.live.rules.write().await;
        rules.apply_payload(RulesPayload {
            rules: old_map,
            computed_at: Utc.with_ymd_and_hms(2026, 5, 8, 9, 0, 0).unwrap(),
        });
    }

    let new_id = Uuid::new_v4();
    let app = api::router().with_state(state.clone());
    let body = serde_json::json!({
        "rules": {
            new_id.to_string(): { "enabled": false, "reason": "new-only" }
        },
        "computed_at": Utc.with_ymd_and_hms(2026, 5, 8, 10, 0, 0).unwrap().to_rfc3339(),
    });

    let request = common::http::request(Method::POST, "/api/rules", Some(body));
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let rules = state.live.rules.read().await;
    assert_eq!(rules.decision(&new_id), (false, Some("new-only")));
    assert_eq!(rules.decision(&old_id), (true, None));
}

#[tokio::test]
async fn push_rules_rejects_malformed_json_body() {
    let state = common::test_state();
    let app = api::router().with_state(state);

    let request = common::http::request(
        Method::POST,
        "/api/rules",
        Some(serde_json::json!({
            "rules": "not-an-object",
            "computed_at": 123,
        })),
    );

    let response = app.oneshot(request).await.unwrap();
    assert!(
        response.status() == StatusCode::BAD_REQUEST
            || response.status() == StatusCode::UNPROCESSABLE_ENTITY
    );
}

#[tokio::test]
async fn push_rules_rejects_missing_computed_at() {
    let state = common::test_state();
    let app = api::router().with_state(state);

    let request = common::http::request(
        Method::POST,
        "/api/rules",
        Some(serde_json::json!({
            "rules": {},
        })),
    );

    let response = app.oneshot(request).await.unwrap();
    assert!(
        response.status() == StatusCode::BAD_REQUEST
            || response.status() == StatusCode::UNPROCESSABLE_ENTITY
    );
}

#[tokio::test]
async fn push_rules_rejects_missing_rules_object() {
    let state = common::test_state();
    let app = api::router().with_state(state);

    let request = common::http::request(
        Method::POST,
        "/api/rules",
        Some(serde_json::json!({
            "computed_at": "2026-05-08T10:00:00Z",
        })),
    );

    let response = app.oneshot(request).await.unwrap();
    assert!(
        response.status() == StatusCode::BAD_REQUEST
            || response.status() == StatusCode::UNPROCESSABLE_ENTITY
    );
}

#[tokio::test]
async fn push_rules_empty_payload_clears_existing_snapshot() {
    let state = common::test_state();

    let old_id = Uuid::new_v4();
    {
        let mut rules = state.live.rules.write().await;
        let mut old = HashMap::new();
        old.insert(
            old_id,
            RuleEntry {
                enabled: false,
                reason: "old".to_string(),
            },
        );
        rules.apply_payload(RulesPayload {
            rules: old,
            computed_at: Utc.with_ymd_and_hms(2026, 5, 8, 8, 0, 0).unwrap(),
        });
    }

    let app = api::router().with_state(state.clone());
    let body = serde_json::json!({
        "rules": {},
        "computed_at": Utc.with_ymd_and_hms(2026, 5, 8, 11, 0, 0).unwrap().to_rfc3339(),
    });

    let request = common::http::request(Method::POST, "/api/rules", Some(body));
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let payload = common::http::response_json(response).await;
    assert_eq!(payload["enabled"], serde_json::json!(0));
    assert_eq!(payload["disabled"], serde_json::json!(0));

    let rules = state.live.rules.read().await;
    assert_eq!(rules.by_strategy_id.len(), 0);
    assert_eq!(rules.decision(&old_id), (true, None));
}

#[tokio::test]
async fn push_rules_accepts_large_payload() {
    let state = common::test_state();
    let app = api::router().with_state(state.clone());

    let mut rules = serde_json::Map::new();
    for i in 0..1000 {
        let id = Uuid::new_v4().to_string();
        rules.insert(
            id,
            serde_json::json!({
                "enabled": i % 2 == 0,
                "reason": format!("bulk-{}", i),
            }),
        );
    }

    let body = serde_json::json!({
        "rules": rules,
        "computed_at": Utc.with_ymd_and_hms(2026, 5, 8, 12, 0, 0).unwrap().to_rfc3339(),
    });

    let request = common::http::request(Method::POST, "/api/rules", Some(body));
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let payload = common::http::response_json(response).await;
    assert_eq!(payload["enabled"], serde_json::json!(500));
    assert_eq!(payload["disabled"], serde_json::json!(500));

    let rules = state.live.rules.read().await;
    assert_eq!(rules.by_strategy_id.len(), 1000);
}

#[tokio::test]
async fn push_rules_duplicate_strategy_key_uses_last_value() {
    let state = common::test_state();
    let app = api::router().with_state(state.clone());

    let dup_id = Uuid::new_v4();
    let raw_body = format!(
        r#"{{
            "rules": {{
                "{id}": {{"enabled": true, "reason": "first"}},
                "{id}": {{"enabled": false, "reason": "second"}}
            }},
            "computed_at": "2026-05-08T13:00:00Z"
        }}"#,
        id = dup_id
    );

    let request = common::http::request_raw_json(Method::POST, "/api/rules", &raw_body);
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let rules = state.live.rules.read().await;
    assert_eq!(rules.decision(&dup_id), (false, Some("second")));
}
