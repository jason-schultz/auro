use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::{broadcast, RwLock};

use chrono::{DateTime, Utc};
use lru::LruCache;
use sqlx::PgPool;

use crate::api::evaluator::EvaluateResponse;
use crate::config::Config;
use crate::engine::types::{BufferKey, CandleAccumulator, CandleBuffer, OpenPosition};
use crate::oanda::client::OandaClient;
use crate::oanda::models::StreamMessage;

#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub config: Config,
    pub oanda: OandaClient,
    pub live: Arc<LiveState>,
    pub price_tx: broadcast::Sender<StreamMessage>,
    pub eval_cache: Arc<Mutex<LruCache<String, EvaluateResponse>>>,
}

pub struct LiveState {
    pub buffers: RwLock<HashMap<BufferKey, CandleBuffer>>,
    pub accumulators: RwLock<HashMap<BufferKey, CandleAccumulator>>,
    pub open_positions: RwLock<HashMap<String, OpenPosition>>,
    pub last_eval_minute: RwLock<HashMap<String, u32>>,
    pub last_quotes: RwLock<HashMap<String, LastQuote>>,
}

impl LiveState {
    pub fn new() -> Self {
        Self {
            buffers: RwLock::new(HashMap::new()),
            accumulators: RwLock::new(HashMap::new()),
            open_positions: RwLock::new(HashMap::new()),
            last_eval_minute: RwLock::new(HashMap::new()),
            last_quotes: RwLock::new(HashMap::new()),
        }
    }
}

impl Default for LiveState {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone)]
pub struct LastQuote {
    pub mid: f64,
    pub bid: f64,
    pub ask: f64,
    pub at: DateTime<Utc>,
}
