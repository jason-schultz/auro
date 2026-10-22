//! Tick consumer: keeps the latest quote per instrument and tracks open
//! positions' excursions. Bars come from the candle feed, never from ticks.

use chrono::{DateTime, Utc};
use tokio::sync::broadcast;

use crate::brokers::oanda::models::{StreamMessage, StreamPrice};
use crate::engine::types::OpenPosition;
use crate::state::{AppState, LastQuote};

use super::trade_management;

pub fn spawn_quote_tracker(mut rx: broadcast::Receiver<StreamMessage>, state: AppState) {
    tokio::spawn(async move {
        tracing::info!("Quote tracker started");

        loop {
            match rx.recv().await {
                Ok(StreamMessage::PRICE(price)) => {
                    let Some(quote) = parse_quote(&price) else {
                        continue;
                    };
                    state
                        .live
                        .last_quotes
                        .write()
                        .await
                        .insert(price.instrument.clone(), quote.clone());

                    let positions: Vec<OpenPosition> = {
                        let positions = state.live.open_positions.read().await;
                        positions
                            .values()
                            .filter(|p| p.instrument == price.instrument)
                            .cloned()
                            .collect()
                    };
                    for pos in &positions {
                        trade_management::update_mae_mfe(&state, pos, quote.mid).await;
                    }
                }
                Ok(StreamMessage::HEARTBEAT(_)) => {}
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    tracing::warn!("Quote tracker lagged, skipped {} messages", n);
                }
                Err(broadcast::error::RecvError::Closed) => {
                    tracing::info!("Quote tracker channel closed");
                    break;
                }
            }
        }
    });
}

fn parse_quote(price: &StreamPrice) -> Option<LastQuote> {
    let bid: f64 = price.bids.first()?.price.parse().ok()?;
    let ask: f64 = price.asks.first()?.price.parse().ok()?;
    let at: DateTime<Utc> = DateTime::parse_from_rfc3339(&price.time)
        .ok()?
        .with_timezone(&Utc);
    Some(LastQuote {
        mid: (bid + ask) / 2.0,
        bid,
        ask,
        at,
    })
}
