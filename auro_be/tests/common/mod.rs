pub mod http;

use std::num::NonZeroUsize;
use std::sync::{Arc, Mutex};

use auro::brokers::oanda::client::OandaClient;
use auro::brokers::wealthsimple::client::WealthsimpleClient;
use auro::config::Config;
use auro::state::{AppState, LiveState};
use lru::LruCache;
use sqlx::postgres::PgPoolOptions;
use tokio::sync::broadcast;

pub fn test_state() -> AppState {
    let db = PgPoolOptions::new()
        .connect_lazy("postgres://test:test@localhost/test")
        .expect("lazy pool should build");

    let config = Config {
        database_url: "postgres://test:test@localhost/test".to_string(),
        oanda_api_key: "test-key".to_string(),
        oanda_account_id: "test-account".to_string(),
        oanda_base_url: "http://localhost:9999".to_string(),
        oanda_stream_url: "http://localhost:9998".to_string(),
        host: "127.0.0.1".to_string(),
        port: 3000,
        questrade_refresh_token: None,
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
        start_time: chrono::Utc::now(),
        live: Arc::new(LiveState::new()),
        price_tx,
        eval_cache: Arc::new(Mutex::new(LruCache::new(NonZeroUsize::new(64).unwrap()))),
        questrade: None,
        wealthsimple,
    }
}
