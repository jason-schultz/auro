pub mod http;

use std::sync::Arc;

use auro::brokers::oanda::client::OandaClient;
use auro::brokers::questrade::link::QuestradeLink;
use auro::brokers::wealthsimple::client::WealthsimpleClient;
use auro::config::Config;
use auro::state::{AppState, LiveState};
use sqlx::postgres::PgPoolOptions;
use tokio::sync::broadcast;

pub fn test_state() -> AppState {
    let db = PgPoolOptions::new()
        .connect_lazy("postgres://test:test@localhost/test")
        .expect("lazy pool should build");

    let config = Config {
        mode: auro::config::Mode::Live,
        database_url: "postgres://test:test@localhost/test".to_string(),
        db_pool_size: 1,
        oanda_api_key: "test-key".to_string(),
        oanda_account_id: "test-account".to_string(),
        oanda_base_url: "http://localhost:9999".to_string(),
        oanda_stream_url: "http://localhost:9998".to_string(),
        host: "127.0.0.1".to_string(),
        port: 3000,
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
        start_time: chrono::Utc::now(),
        live: Arc::new(LiveState::new()),
        price_tx,
        questrade: Arc::new(QuestradeLink::default()),
        wealthsimple,
        massive: None,
    }
}
