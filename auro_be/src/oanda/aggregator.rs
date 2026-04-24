use chrono::{Duration, Timelike, Utc};
use sqlx::PgPool;
use std::collections::HashMap;
use tokio::sync::broadcast;

use crate::db;
use crate::oanda::models::{CandleRecord, StreamMessage};

struct BarBuilder {
    instrument: String,
    timestamp: chrono::DateTime<chrono::Utc>,
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    tick_count: i32,
}

impl BarBuilder {
    fn new(instrument: &str, timestamp: chrono::DateTime<chrono::Utc>, price: f64) -> Self {
        Self {
            instrument: instrument.to_string(),
            timestamp,
            open: price,
            high: price,
            low: price,
            close: price,
            tick_count: 1,
        }
    }

    fn update(&mut self, price: f64) {
        self.high = self.high.max(price);
        self.low = self.low.min(price);
        self.close = price;
        self.tick_count += 1;
    }

    fn to_record(&self) -> CandleRecord {
        CandleRecord {
            instrument: self.instrument.clone(),
            granularity: "M1".to_string(),
            timestamp: self.timestamp,
            open: self.open,
            high: self.high,
            low: self.low,
            close: self.close,
            volume: self.tick_count,
            complete: true,
        }
    }
}

/// Snap a timestamp down to the start of its 1-minute window
fn snap_to_minute(ts: chrono::DateTime<chrono::Utc>) -> chrono::DateTime<chrono::Utc> {
    ts.with_timezone(&Utc)
        - Duration::seconds(ts.second() as i64)
        - Duration::nanoseconds(ts.nanosecond() as i64)
}

pub fn spawn_aggregator(mut rx: broadcast::Receiver<StreamMessage>, pool: PgPool) {
    tokio::spawn(async move {
        let mut bars: HashMap<String, BarBuilder> = HashMap::new();

        loop {
            match rx.recv().await {
                Ok(StreamMessage::PRICE(price)) => {
                    let bid: f64 = match price.bids.first() {
                        Some(b) => match b.price.parse() {
                            Ok(v) => v,
                            Err(_) => continue,
                        },
                        None => continue,
                    };
                    let ask: f64 = match price.asks.first() {
                        Some(a) => match a.price.parse() {
                            Ok(v) => v,
                            Err(_) => continue,
                        },
                        None => continue,
                    };
                    let mid = (bid + ask) / 2.0;

                    let tick_time = match chrono::DateTime::parse_from_rfc3339(&price.time) {
                        Ok(t) => t.with_timezone(&Utc),
                        Err(_) => continue,
                    };

                    let minute = snap_to_minute(tick_time);

                    match bars.get_mut(&price.instrument) {
                        Some(bar) if bar.timestamp == minute => {
                            bar.update(mid);
                        }
                        Some(bar) => {
                            // Minute rolled over — save the completed bar
                            let record = bar.to_record();
                            if let Err(e) = db::upsert_candle(&pool, &record).await {
                                tracing::error!(
                                    "Failed to save candle for {}: {}",
                                    record.instrument,
                                    e
                                );
                            } else {
                                tracing::debug!(
                                    "Saved M1 candle for {} at {}",
                                    record.instrument,
                                    record.timestamp
                                );
                            }

                            // Start new bar
                            *bar = BarBuilder::new(&price.instrument, minute, mid);
                        }
                        None => {
                            bars.insert(
                                price.instrument.clone(),
                                BarBuilder::new(&price.instrument, minute, mid),
                            );
                        }
                    }
                }
                Ok(StreamMessage::HEARTBEAT(_)) => {}
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    tracing::warn!("Aggregator lagged, skipped {} messages", n);
                }
                Err(broadcast::error::RecvError::Closed) => {
                    tracing::info!("Aggregator channel closed, shutting down");
                    break;
                }
            }
        }
    });
}
