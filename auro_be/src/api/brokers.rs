use axum::extract::State;
use axum::Json;

use crate::brokers::client::BrokerClient;
use crate::brokers::{BrokerKind, BrokerStatus};
use crate::error::AppResult;
use crate::state::AppState;

pub async fn list_brokers(State(state): State<AppState>) -> AppResult<Json<Vec<BrokerStatus>>> {
    let oanda_status = state.oanda.clone().broker_status().await;

    let questrade_status = if let Some(qt) = state.questrade.as_ref() {
        let mut client = qt.lock().await;
        client.broker_status().await
    } else {
        BrokerStatus {
            broker: BrokerKind::Questrade,
            display_name: "Questrade",
            connected: false,
            error: None,
            accounts: vec![],
        }
    };

    let wealthsimple_status = state.wealthsimple.clone().broker_status().await;

    Ok(Json(vec![
        oanda_status,
        questrade_status,
        wealthsimple_status,
    ]))
}
