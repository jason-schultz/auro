//! The live/tester split (AGENTS.md): the live process never serves a
//! backtest, pipeline or report endpoint, and the tester never serves
//! anything that trades, streams prices or touches live state.

mod common;

use axum::http::{Method, StatusCode};
use axum::Router;
use common::http::request;
use serde_json::json;
use tower::ServiceExt;

/// Heavy test work: served by the tester only.
const TESTER_ONLY: &[(&str, &str)] = &[
    ("POST", "/api/pipeline/backtest"),
    ("POST", "/api/pipeline/walk_forward"),
    ("POST", "/api/pipeline/monte_carlo"),
    ("POST", "/api/pipeline/parameter_stability"),
    ("POST", "/api/pipeline/holdout"),
    ("POST", "/api/strategy/signal-preview"),
    ("POST", "/api/strategy/report"),
    ("POST", "/api/strategy/sensitivity"),
    ("POST", "/api/strategy/portfolio"),
    ("POST", "/api/strategy/trades"),
];

/// Orders, the price stream, live state and broker calls: live only.
const LIVE_ONLY: &[(&str, &str)] = &[
    ("POST", "/api/rules"),
    ("DELETE", "/api/positions/123"),
    ("GET", "/ws/prices"),
    ("GET", "/api/health/live"),
    ("GET", "/api/account"),
    ("GET", "/api/pricing"),
    ("GET", "/api/open-trades"),
    ("GET", "/api/instruments"),
    ("POST", "/api/instruments/enrich"),
    ("POST", "/api/candles/backfill"),
    ("GET", "/api/indicators/EUR_USD/H1"),
    ("GET", "/api/live/strategies"),
    ("POST", "/api/live/strategies"),
    ("PUT", "/api/live/strategies/abc"),
    ("DELETE", "/api/live/strategies/abc"),
    ("POST", "/api/live/strategies/abc/toggle"),
    ("GET", "/api/live/trades"),
    ("PUT", "/api/live/config"),
    ("GET", "/api/debug/positions"),
    ("GET", "/api/debug/buffers"),
    ("GET", "/api/brokers"),
    ("POST", "/api/financing/snapshot"),
    ("POST", "/api/questrade/connect"),
    ("POST", "/api/questrade/candles/persist"),
    ("POST", "/api/questrade/options/snapshot"),
    ("POST", "/api/massive/candles/persist"),
    ("POST", "/api/options/scenarios"),
];

async fn status(router: Router<auro::state::AppState>, method: &str, uri: &str) -> StatusCode {
    let app = router.with_state(common::test_state());
    let method = Method::from_bytes(method.as_bytes()).unwrap();
    let body = (method != Method::GET && method != Method::DELETE).then(|| json!({}));
    app.oneshot(request(method, uri, body))
        .await
        .unwrap()
        .status()
}

#[tokio::test]
async fn live_router_serves_no_test_endpoint() {
    for (method, uri) in TESTER_ONLY {
        assert_eq!(
            status(auro::api::live_router(), method, uri).await,
            StatusCode::NOT_FOUND,
            "live serves {method} {uri}; it belongs to the tester"
        );
    }
}

#[tokio::test]
async fn tester_router_serves_every_test_endpoint() {
    // An empty body is refused by the handler's extractor (no DB, no
    // engine work): proof the route exists without running a backtest.
    for (method, uri) in TESTER_ONLY {
        assert_ne!(
            status(auro::api::tester_router(), method, uri).await,
            StatusCode::NOT_FOUND,
            "tester doesn't serve {method} {uri}"
        );
    }
}

#[tokio::test]
async fn tester_router_serves_nothing_that_trades_or_streams() {
    for (method, uri) in LIVE_ONLY {
        assert_eq!(
            status(auro::api::tester_router(), method, uri).await,
            StatusCode::NOT_FOUND,
            "tester serves {method} {uri}; it belongs to the live engine"
        );
    }
}

#[tokio::test]
async fn both_serve_the_shared_lookups() {
    // Missing query parameters: refused before any DB read.
    for router in [auro::api::live_router(), auro::api::tester_router()] {
        assert_eq!(
            status(router, "GET", "/api/candles").await,
            StatusCode::BAD_REQUEST
        );
    }
}
