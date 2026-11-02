use std::time::Duration;

use futures_util::StreamExt;
use tokio::sync::broadcast;

use crate::brokers::oanda::client::OandaClient;
use crate::brokers::oanda::models::StreamMessage;

/// OANDA sends a heartbeat every 5 seconds; this much silence means the
/// connection is dead even if the socket still looks open, so reconnect.
const SILENCE_LIMIT: Duration = Duration::from_secs(30);

/// Characters of an unparseable line kept in the log.
const LOGGED_CHARS: usize = 200;

/// Connect to the OANDA pricing stream and broadcast parsed messages to all
/// subscribers, reconnecting whenever the stream ends, errors or goes quiet.
/// Runs forever; started under a supervisor (`engine::live::spawn_supervised`).
pub async fn run_price_stream(
    oanda: OandaClient,
    instruments: Vec<String>,
    tx: broadcast::Sender<StreamMessage>,
) {
    let mut key_changes = oanda.key_changes();
    'connect: loop {
        tracing::info!("Connecting to OANDA price stream...");
        // A key saved before this connect is the one it uses.
        key_changes.borrow_and_update();

        let instrument_refs: Vec<&str> = instruments.iter().map(|s| s.as_str()).collect();

        match oanda.pricing_stream(&instrument_refs).await {
            Ok(response) => {
                tracing::info!("OANDA price stream connected");

                let mut stream = response.bytes_stream();
                // Bytes, not text: a character split across two chunks is
                // only decoded once its line is complete.
                let mut buffer: Vec<u8> = Vec::new();

                loop {
                    let next = tokio::select! {
                        next = tokio::time::timeout(SILENCE_LIMIT, stream.next()) => next,
                        _ = key_changes.changed() => {
                            // At once: nothing is wrong with OANDA.
                            tracing::info!("OANDA key changed; reconnecting the price stream with it");
                            continue 'connect;
                        }
                    };
                    let chunk = match next {
                        Ok(Some(chunk)) => chunk,
                        Ok(None) => break,
                        Err(_) => {
                            tracing::warn!(
                                "OANDA price stream silent for {}s; reconnecting",
                                SILENCE_LIMIT.as_secs()
                            );
                            break;
                        }
                    };
                    let bytes = match chunk {
                        Ok(bytes) => bytes,
                        Err(e) => {
                            tracing::error!("Stream read error: {}", e);
                            break;
                        }
                    };
                    buffer.extend_from_slice(&bytes);

                    while let Some(newline) = buffer.iter().position(|b| *b == b'\n') {
                        let line_bytes: Vec<u8> = buffer.drain(..=newline).collect();
                        let line = String::from_utf8_lossy(&line_bytes);
                        let line = line.trim();
                        if line.is_empty() {
                            continue;
                        }

                        match serde_json::from_str::<StreamMessage>(line) {
                            // No subscriber is a normal moment (the quote
                            // tracker restarting): the message is dropped.
                            Ok(msg) => {
                                let _ = tx.send(msg);
                            }
                            Err(e) => {
                                let shown: String = line.chars().take(LOGGED_CHARS).collect();
                                tracing::warn!(
                                    "Failed to parse stream message: {} | Line: {}",
                                    e,
                                    shown
                                );
                            }
                        }
                    }
                }

                tracing::warn!("OANDA price stream disconnected");
            }
            Err(e) => {
                tracing::error!("Failed to connect to OANDA stream: {}", e);
            }
        }

        tracing::info!("Reconnecting to OANDA stream in 5 seconds...");
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::extract::State;
    use axum::http::HeaderMap;
    use axum::routing::get;
    use axum::Router;
    use tokio::sync::mpsc;

    /// A stand-in pricing stream that reports each connection's key and
    /// sends heartbeats until the client goes away.
    async fn stand_in(keys: mpsc::UnboundedSender<String>) -> String {
        async fn stream(
            State(keys): State<mpsc::UnboundedSender<String>>,
            headers: HeaderMap,
        ) -> Body {
            let key = headers
                .get("authorization")
                .and_then(|v| v.to_str().ok())
                .unwrap_or_default()
                .trim_start_matches("Bearer ")
                .to_string();
            keys.send(key).unwrap();
            let beats = futures_util::stream::unfold((), |()| async {
                tokio::time::sleep(Duration::from_millis(50)).await;
                let line = "{\"type\":\"HEARTBEAT\",\"time\":\"2026-11-01T00:00:00Z\"}\n";
                Some((Ok::<_, std::io::Error>(line.to_string()), ()))
            });
            Body::from_stream(beats)
        }
        let app = Router::new()
            .route("/v3/accounts/{id}/pricing/stream", get(stream))
            .with_state(keys);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        format!("http://{addr}")
    }

    #[tokio::test]
    async fn a_new_key_reconnects_the_stream_with_it_at_once() {
        let (keys_tx, mut keys) = mpsc::unbounded_channel();
        let url = stand_in(keys_tx).await;
        let oanda = OandaClient::new(&url, &url, "old-key", "101-test-001");
        let (tx, _) = broadcast::channel(16);
        let task = tokio::spawn(run_price_stream(
            oanda.clone(),
            vec!["EUR_USD".to_string()],
            tx,
        ));

        let wait = Duration::from_secs(2);
        assert_eq!(
            tokio::time::timeout(wait, keys.recv())
                .await
                .unwrap()
                .unwrap(),
            "old-key"
        );
        assert!(oanda.set_key("new-key"));
        // Well inside the 5-second pause an ordinary drop waits.
        assert_eq!(
            tokio::time::timeout(wait, keys.recv())
                .await
                .unwrap()
                .unwrap(),
            "new-key"
        );
        task.abort();
    }
}
