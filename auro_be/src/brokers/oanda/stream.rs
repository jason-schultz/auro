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
    loop {
        tracing::info!("Connecting to OANDA price stream...");

        let instrument_refs: Vec<&str> = instruments.iter().map(|s| s.as_str()).collect();

        match oanda.pricing_stream(&instrument_refs).await {
            Ok(response) => {
                tracing::info!("OANDA price stream connected");

                let mut stream = response.bytes_stream();
                // Bytes, not text: a character split across two chunks is
                // only decoded once its line is complete.
                let mut buffer: Vec<u8> = Vec::new();

                loop {
                    let chunk = match tokio::time::timeout(SILENCE_LIMIT, stream.next()).await {
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
