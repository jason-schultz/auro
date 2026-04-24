use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::response::IntoResponse;
use futures_util::{SinkExt, StreamExt};

use crate::state::AppState;
use crate::oanda::models::StreamMessage;

pub async fn ws_prices(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_ws(socket, state))
}

async fn handle_ws(socket: WebSocket, state: AppState) {
    let (mut sender, mut receiver) = socket.split();
    let mut rx = state.price_tx.subscribe();

    tracing::info!("WebSocket client connected");

    // Spawn a task to forward broadcast messages to this WebSocket client
    let mut send_task = tokio::spawn(async move {
        while let Ok(msg) = rx.recv().await {
            let json = match &msg {
                StreamMessage::PRICE(price) => {
                    // Send a simplified price update to the frontend
                    let bid = price.bids.first().map(|b| &b.price);
                    let ask = price.asks.first().map(|a| &a.price);

                    serde_json::json!({
                        "type": "price",
                        "instrument": price.instrument,
                        "time": price.time,
                        "bid": bid,
                        "ask": ask,
                        "tradeable": price.tradeable,
                    })
                }
                StreamMessage::HEARTBEAT(hb) => {
                    serde_json::json!({
                        "type": "heartbeat",
                        "time": hb.time,
                    })
                }
            };

            if let Ok(text) = serde_json::to_string(&json) {
                if sender.send(Message::Text(text.into())).await.is_err() {
                    break;
                }
            }
        }
    });

    // Listen for client messages (or disconnection)
    let mut recv_task = tokio::spawn(async move {
        while let Some(Ok(_msg)) = receiver.next().await {
            // We don't expect messages from the client yet,
            // but we need to keep reading to detect disconnection.
        }
    });

    // If either task completes, abort the other
    tokio::select! {
        _ = &mut send_task => {
            recv_task.abort();
        }
        _ = &mut recv_task => {
            send_task.abort();
        }
    }

    tracing::info!("WebSocket client disconnected");
}
