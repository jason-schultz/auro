use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{broadcast, RwLock};

use chrono::{DateTime, Utc};
use sqlx::PgPool;

use crate::brokers::connections::Connections;
use crate::brokers::oanda::client::OandaClient;
use crate::brokers::oanda::models::StreamMessage;
use crate::brokers::questrade::link::QuestradeLink;
use crate::brokers::wealthsimple::client::WealthsimpleClient;
use crate::config::Config;
use crate::engine::live::account_cache::AccountSnapshot;
use crate::engine::live::instrument_cache::InstrumentMeta;
use crate::engine::rules::Rules;
use crate::engine::types::{BufferKey, CandleBuffer, Granularity, OpenPosition};

#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub config: Config,
    pub oanda: OandaClient,
    pub start_time: DateTime<Utc>,
    pub live: Arc<LiveState>,
    pub price_tx: broadcast::Sender<StreamMessage>,
    /// The Questrade connection; empty until connected, replaceable while
    /// running (`POST /api/questrade/connect`). Always empty in the tester.
    pub questrade: Arc<QuestradeLink>,
    pub wealthsimple: WealthsimpleClient,
    /// Massive, replaceable while running, and what Settings shows about
    /// each changeable connection (`api::settings`).
    pub connections: Arc<Connections>,
}

pub struct LiveState {
    pub buffers: RwLock<HashMap<BufferKey, CandleBuffer>>,
    pub account: Arc<RwLock<Option<AccountSnapshot>>>,
    pub instrument_metadata: RwLock<HashMap<String, InstrumentMeta>>,
    pub open_positions: RwLock<HashMap<String, OpenPosition>>,
    #[allow(clippy::type_complexity)]
    pub eval_locks: RwLock<HashMap<(String, Granularity), Arc<tokio::sync::Mutex<()>>>>,
    pub last_evaluator_run: RwLock<Option<DateTime<Utc>>>,
    pub last_candle_persisted: RwLock<Option<DateTime<Utc>>>,
    pub last_quotes: RwLock<HashMap<String, LastQuote>>,
    pub rules: RwLock<Rules>,
    /// Whether `open_positions` has been checked against OANDA since
    /// startup (prefill or a position sync). Entries wait until it has:
    /// a map that missed a trade OANDA holds would open a duplicate.
    pub positions_known: RwLock<bool>,
    /// Trades open at OANDA with no `live_trades` row, so nothing manages
    /// them beyond their own stop; from the last position sync.
    pub untracked_trades: RwLock<Vec<UntrackedTrade>>,
}

/// A trade OANDA holds that Auro has no record of.
#[derive(Debug, Clone, serde::Serialize)]
pub struct UntrackedTrade {
    pub id: String,
    pub instrument: String,
    pub units: String,
}

impl LiveState {
    pub fn new() -> Self {
        Self {
            buffers: RwLock::new(HashMap::new()),
            account: Arc::new(RwLock::new(None)),
            instrument_metadata: RwLock::new(HashMap::new()),
            open_positions: RwLock::new(HashMap::new()),
            eval_locks: RwLock::new(HashMap::new()),
            last_evaluator_run: RwLock::new(None),
            last_candle_persisted: RwLock::new(None),
            last_quotes: RwLock::new(HashMap::new()),
            rules: RwLock::new(Rules::default()),
            positions_known: RwLock::new(false),
            untracked_trades: RwLock::new(Vec::new()),
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

#[cfg(test)]
impl AppState {
    /// The one `AppState` for in-crate tests. `db` may be a lazy pool for
    /// tests that never touch Postgres; OANDA points at a dead local port.
    pub(crate) fn for_tests(db: PgPool) -> Self {
        let config = Config {
            mode: crate::config::Mode::Live,
            database_url: "postgres://test:test@localhost/test".to_string(),
            db_pool_size: 1,
            oanda_api_key: "test-key".to_string(),
            oanda_account_id: "test-account".to_string(),
            oanda_base_url: "http://127.0.0.1:1".to_string(),
            oanda_stream_url: "http://127.0.0.1:1".to_string(),
            host: "127.0.0.1".to_string(),
            port: 0,
            questrade_refresh_token: None,
            massive_api_key: None,
            massive_base_url: "http://127.0.0.1:1".to_string(),
            massive_calls_per_minute: 0,
        };
        let oanda = OandaClient::new(
            &config.oanda_base_url,
            &config.oanda_stream_url,
            &config.oanda_api_key,
            &config.oanda_account_id,
        );
        let (price_tx, _) = broadcast::channel(8);
        let wealthsimple = WealthsimpleClient::new(&db);

        AppState {
            db,
            config,
            oanda,
            start_time: Utc::now(),
            live: Arc::new(LiveState::new()),
            price_tx,
            questrade: Arc::new(QuestradeLink::default()),
            wealthsimple,
            connections: Arc::new(Connections::default()),
        }
    }

    /// `for_tests` with a lazy pool that never connects.
    pub(crate) fn for_tests_without_db() -> Self {
        let db = sqlx::postgres::PgPoolOptions::new()
            .connect_lazy("postgres://test:test@localhost/test")
            .expect("lazy pool should build");
        Self::for_tests(db)
    }

    /// `for_tests` against the migrated test database named by
    /// `AURO_TEST_DATABASE_URL`. Only for `#[ignore]`d DB-backed tests.
    pub(crate) async fn for_tests_with_test_db() -> Self {
        let url = std::env::var("AURO_TEST_DATABASE_URL")
            .expect("AURO_TEST_DATABASE_URL must point at a migrated test database");
        let db = PgPool::connect(&url)
            .await
            .expect("failed connecting to AURO_TEST_DATABASE_URL");
        Self::for_tests(db)
    }
}
