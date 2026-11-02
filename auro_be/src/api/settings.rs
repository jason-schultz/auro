//! Settings saved on Opus's Settings page, applied without a restart.
//!
//! `POST /api/settings/apply` reads one connection's saved values (each
//! ahead of `.env`, as at startup), checks them with one read-only call and
//! only then puts them in use; a failed check keeps what's in use. OANDA's
//! account and addresses are not switched while running: the positions,
//! sizing and safety state in memory belong to the account they came from,
//! so a change there waits for a restart and says so.
//!
//! `GET /api/settings/status` is what the Settings cards show. Both are
//! live-only: the tester uses none of these connections.

use axum::extract::State;
use axum::Json;
use chrono::Utc;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::brokers::connections::{self, ConnectionStatus};
use crate::brokers::massive::client::MassiveClient;
use crate::brokers::oanda::models::Account;
use crate::config::Config;
use crate::error::{AppError, AppResult};
use crate::state::AppState;

/// The ticker a Massive key is checked against: one small reference read.
const MASSIVE_CHECK_TICKER: &str = "SPY";

#[derive(Debug, Deserialize)]
pub struct ApplyRequest {
    pub connection: String,
}

/// `POST /api/settings/apply` with `{"connection": "oanda" | "massive"}`.
pub async fn apply(
    State(state): State<AppState>,
    Json(body): Json<ApplyRequest>,
) -> AppResult<Json<Value>> {
    let stored = crate::stored_settings(&state.db)
        .await
        .map_err(|e| AppError::Internal(format!("reading saved settings: {e}")))?;
    let wanted = Config::from_stored(state.config.mode, &stored)
        .map_err(|e| AppError::BadRequest(e.to_string()))?;

    let status = match body.connection.as_str() {
        connections::OANDA => apply_oanda(&state, &wanted).await,
        connections::MASSIVE => apply_massive(&state, &wanted).await,
        other => {
            return Err(AppError::BadRequest(format!(
                "{other} isn't a connection the engine applies"
            )))
        }
    };
    Ok(Json(
        json!({ "connection": body.connection, "status": status }),
    ))
}

/// `GET /api/settings/status`: each connection's status, by name.
pub async fn status(State(state): State<AppState>) -> Json<Value> {
    Json(json!(state.connections.statuses()))
}

/// What a passing OANDA check says.
pub(crate) fn oanda_answered(account: &Account) -> String {
    format!(
        "OANDA answered for account {} ({}).",
        account.id, account.currency
    )
}

async fn apply_oanda(state: &AppState, wanted: &Config) -> ConnectionStatus {
    let oanda = &state.oanda;
    let now = Utc::now();
    let switching = wanted.oanda_account_id != oanda.account_id()
        || wanted.oanda_base_url.trim_end_matches('/') != oanda.base_url()
        || wanted.oanda_stream_url.trim_end_matches('/') != oanda.stream_url();

    if switching {
        state.connections.update(connections::OANDA, |status| {
            status.checked_at = Some(now);
            status.restart_to_switch = true;
            status.words = Some(
                "The saved account or address differs from the one trading. It applies \
                 when the engine restarts; the current account keeps trading until then."
                    .to_string(),
            );
        });
        return state.connections.status(connections::OANDA);
    }

    state.connections.update(connections::OANDA, |status| {
        status.restart_to_switch = false
    });
    match oanda.try_key(&wanted.oanda_api_key).await {
        Ok(account) => {
            let changed = oanda.set_key(&wanted.oanda_api_key);
            if changed {
                tracing::info!("OANDA key changed from Settings; in use now");
            }
            let words = oanda_answered(&account);
            state
                .connections
                .record_check(connections::OANDA, now, true, words, changed);
        }
        Err(e) => {
            tracing::warn!("A saved OANDA key was refused; keeping the one in use: {e}");
            state.connections.record_check(
                connections::OANDA,
                now,
                false,
                format!("OANDA refused it ({e}). Still using the previous key."),
                false,
            );
        }
    }
    state.connections.status(connections::OANDA)
}

async fn apply_massive(state: &AppState, wanted: &Config) -> ConnectionStatus {
    let now = Utc::now();
    let Some(key) = wanted.massive_api_key.as_deref() else {
        state.connections.record_check(
            connections::MASSIVE,
            now,
            false,
            "No Massive key is saved or in .env.".to_string(),
            false,
        );
        return state.connections.status(connections::MASSIVE);
    };

    let client = match MassiveClient::new(
        &wanted.massive_base_url,
        key,
        wanted.massive_calls_per_minute,
    ) {
        Ok(client) => client,
        Err(e) => {
            state.connections.record_check(
                connections::MASSIVE,
                now,
                false,
                format!("Couldn't set up Massive ({e}). Still using the previous key."),
                false,
            );
            return state.connections.status(connections::MASSIVE);
        }
    };

    match client.list_splits(MASSIVE_CHECK_TICKER).await {
        Ok(_) => {
            // The checked client is the one put in use, so the call just
            // made counts against its rate limit.
            state.connections.set_massive(client);
            tracing::info!("Massive settings applied from Settings; in use now");
            state.connections.record_check(
                connections::MASSIVE,
                now,
                true,
                "Massive answered with this key.".to_string(),
                true,
            );
        }
        Err(e) => {
            tracing::warn!("Saved Massive settings were refused; keeping the ones in use: {e}");
            state.connections.record_check(
                connections::MASSIVE,
                now,
                false,
                format!("Massive refused it ({e}). Still using the previous key."),
                false,
            );
        }
    }
    state.connections.status(connections::MASSIVE)
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::extract::Path;
    use axum::http::{HeaderMap, StatusCode};
    use axum::response::IntoResponse;
    use axum::routing::get;
    use axum::Router;

    const GOOD: &str = "good-key";

    fn authorized(headers: &HeaderMap) -> bool {
        headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v == format!("Bearer {GOOD}"))
    }

    /// A stand-in OANDA and Massive on a local port: only `GOOD` is accepted.
    async fn stand_in() -> String {
        async fn account(Path(id): Path<String>, headers: HeaderMap) -> impl IntoResponse {
            if !authorized(&headers) {
                return (StatusCode::UNAUTHORIZED, "{\"errorMessage\":\"bad key\"}")
                    .into_response();
            }
            Json(json!({ "account": {
                "id": id, "currency": "CAD", "balance": "100000", "unrealizedPL": "0",
                "pl": "0", "openTradeCount": 0, "openPositionCount": 0,
                "marginUsed": "0", "marginAvailable": "100000"
            }}))
            .into_response()
        }
        async fn splits(headers: HeaderMap) -> impl IntoResponse {
            if !authorized(&headers) {
                return (StatusCode::UNAUTHORIZED, "{\"status\":\"ERROR\"}").into_response();
            }
            Json(json!({ "status": "OK", "results": [] })).into_response()
        }
        let app = Router::new()
            .route("/v3/accounts/{id}", get(account))
            .route("/v3/reference/splits", get(splits));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        format!("http://{addr}")
    }

    /// A state whose OANDA client points at `url` with `key`.
    fn state_at(url: &str, key: &str) -> (AppState, Config) {
        let mut state = AppState::for_tests_without_db();
        state.oanda =
            crate::brokers::oanda::client::OandaClient::new(url, url, key, "101-test-001");
        let mut config = state.config.clone();
        config.oanda_base_url = url.to_string();
        config.oanda_stream_url = url.to_string();
        config.oanda_account_id = "101-test-001".to_string();
        config.massive_base_url = url.to_string();
        (state, config)
    }

    #[tokio::test]
    async fn a_good_oanda_key_is_checked_then_used_and_the_stream_told() {
        let url = stand_in().await;
        let (state, mut wanted) = state_at(&url, "old-key");
        let mut changes = state.oanda.key_changes();
        wanted.oanda_api_key = GOOD.to_string();

        let status = apply_oanda(&state, &wanted).await;

        assert_eq!(status.ok, Some(true));
        assert!(status.in_use_since.is_some());
        assert!(!status.restart_to_switch);
        assert!(changes.has_changed().unwrap());
        changes.borrow_and_update();
        // Every clone now uses it: a plain read succeeds.
        assert!(state.oanda.clone().get_account().await.is_ok());
    }

    #[tokio::test]
    async fn a_refused_oanda_key_keeps_the_one_in_use() {
        let url = stand_in().await;
        let (state, mut wanted) = state_at(&url, GOOD);
        let changes = state.oanda.key_changes();
        wanted.oanda_api_key = "typo-key".to_string();

        let status = apply_oanda(&state, &wanted).await;

        assert_eq!(status.ok, Some(false));
        assert!(status
            .words
            .unwrap()
            .contains("Still using the previous key"));
        assert!(!changes.has_changed().unwrap());
        assert!(state.oanda.get_account().await.is_ok());
    }

    #[tokio::test]
    async fn another_oanda_account_waits_for_a_restart() {
        let url = stand_in().await;
        let (state, mut wanted) = state_at(&url, GOOD);
        wanted.oanda_api_key = GOOD.to_string();
        wanted.oanda_account_id = "001-real-001".to_string();

        let status = apply_oanda(&state, &wanted).await;

        assert!(status.restart_to_switch);
        assert_eq!(state.oanda.account_id(), "101-test-001");

        // Saved back to the running account: the flag clears.
        wanted.oanda_account_id = "101-test-001".to_string();
        assert!(!apply_oanda(&state, &wanted).await.restart_to_switch);
    }

    #[tokio::test]
    async fn massive_is_swapped_in_only_when_its_key_works() {
        let url = stand_in().await;
        let (state, mut wanted) = state_at(&url, GOOD);
        assert!(state.connections.massive().is_none());

        wanted.massive_api_key = Some("typo-key".to_string());
        let status = apply_massive(&state, &wanted).await;
        assert_eq!(status.ok, Some(false));
        assert!(state.connections.massive().is_none());

        wanted.massive_api_key = Some(GOOD.to_string());
        let status = apply_massive(&state, &wanted).await;
        assert_eq!(status.ok, Some(true));
        assert!(status.in_use_since.is_some());
        assert!(state.connections.massive().is_some());
    }
}
