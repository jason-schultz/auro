use futures_util::StreamExt;
use tokio::sync::broadcast;

use crate::oanda::client::OandaClient;
use crate::oanda::models::StreamMessage;

/// Spawns a background task that connects to the OANDA pricing stream
/// and broadcasts parsed messages to all subscribers.
pub fn spawn_price_stream(
    oanda: OandaClient,
    instruments: Vec<String>,
    tx: broadcast::Sender<StreamMessage>,
) {
    tokio::spawn(async move {
        loop {
            tracing::info!("Connecting to OANDA price stream...");

            let instrument_refs: Vec<&str> = instruments.iter().map(|s| s.as_str()).collect();

            match oanda.pricing_stream(&instrument_refs).await {
                Ok(response) => {
                    tracing::info!("OANDA price stream connected");

                    let mut stream = response.bytes_stream();
                    let mut buffer = String::new();

                    while let Some(chunk_result) = stream.next().await {
                        match chunk_result {
                            Ok(bytes) => {
                                let text = match std::str::from_utf8(&bytes) {
                                    Ok(t) => t,
                                    Err(e) => {
                                        tracing::warn!("Invalid UTF-8 from stream: {}", e);
                                        continue;
                                    }
                                };

                                buffer.push_str(text);

                                // Process complete lines
                                while let Some(newline_pos) = buffer.find('\n') {
                                    let line: String = buffer.drain(..=newline_pos).collect();
                                    let line = line.trim();

                                    if line.is_empty() {
                                        continue;
                                    }

                                    match serde_json::from_str::<StreamMessage>(line) {
                                        Ok(msg) => {
                                            // Broadcast to subscribers. If no one is listening,
                                            // that's fine — just drop the message.
                                            let _ = tx.send(msg);
                                        }
                                        Err(e) => {
                                            tracing::warn!(
                                                "Failed to parse stream message: {} | Line: {}",
                                                e,
                                                &line[..line.len().min(200)]
                                            );
                                        }
                                    }
                                }
                            }
                            Err(e) => {
                                tracing::error!("Stream read error: {}", e);
                                break;
                            }
                        }
                    }

                    tracing::warn!("OANDA price stream disconnected");
                }
                Err(e) => {
                    tracing::error!("Failed to connect to OANDA stream: {}", e);
                }
            }

            // Wait before reconnecting
            tracing::info!("Reconnecting to OANDA stream in 5 seconds...");
            tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;
        }
    });
}
