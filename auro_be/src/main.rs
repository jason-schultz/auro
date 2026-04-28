mod api;
mod config;
mod db;
mod engine;
mod error;
mod oanda;
mod state;

use std::sync::Arc;

use crate::config::Config;
use crate::engine::live::spawn_live_evaluator;
use crate::oanda::aggregator::spawn_aggregator;
use crate::oanda::backfill::backfill_candles;
use crate::oanda::client::OandaClient;
use crate::oanda::is_forex_market_open;
use crate::oanda::stream::spawn_price_stream;
use crate::state::{AppState, LiveState};

use tokio::net::TcpListener;
use tokio::sync::broadcast;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing_appender::rolling::{Builder, Rotation};
use tracing_subscriber::fmt::writer::MakeWriterExt;
use tracing_subscriber::EnvFilter;

/// Default instruments to stream on startup.
const DEFAULT_INSTRUMENTS: &[&str] = &[
    // Majors (needed for live strategies)
    "EUR_USD",
    "GBP_USD",
    "USD_CAD",
    "USD_JPY",
    "AUD_USD",
    "XAU_USD",
    // Crosses
    "EUR_JPY",
    "EUR_GBP",
    "EUR_CHF",
    "EUR_CAD",
    "EUR_AUD",
    "GBP_JPY",
    "GBP_AUD",
    "GBP_CAD",
    "AUD_JPY",
    "AUD_NZD",
    "AUD_CAD",
    "NZD_USD",
    "NZD_JPY",
    "NZD_CAD",
    "CAD_JPY",
    "CAD_CHF",
    "CHF_JPY",
    // Commodities
    "WTICO_USD",
    "BCO_USD",
    "NATGAS_USD",
    "XCU_USD",
    "CORN_USD",
    "SOYBN_USD",
    "WHEAT_USD",
    "SUGAR_USD",
    // Metals
    "XAG_USD",
    "XPT_USD",
    "XPD_USD",
    // Indices
    "SPX500_USD",
    "NAS100_USD",
    "US30_USD",
    "UK100_GBP",
    "DE30_EUR",
    "JP225_USD",
    "AU200_AUD",
    "EU50_EUR",
];

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Load .env file
    dotenvy::dotenv().ok();

    let file_appender = Builder::new()
        .filename_prefix("auro")
        .filename_suffix("log")
        .rotation(Rotation::DAILY)
        .max_log_files(7)
        .build("logs")
        .expect("failed to create log file appender");

    let (file_writer, _file_guard) = tracing_appender::non_blocking(file_appender);

    // Initialize tracing
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("auro=debug,tower_http=debug")),
        )
        .with_writer(std::io::stdout.and(file_writer))
        .init();

    // Load config
    let config = Config::from_env().map_err(|e| anyhow::anyhow!("Failed to load config: {}", e))?;

    tracing::info!("Starting Auro on {}", config.listen_addr());

    // Connect to database
    let pool = db::create_pool(&config.database_url).await?;

    // Create OANDA client
    let oanda = OandaClient::new(
        &config.oanda_base_url,
        &config.oanda_stream_url,
        &config.oanda_api_key,
        &config.oanda_account_id,
    );

    // Verify OANDA connection
    match oanda.get_account().await {
        Ok(account) => {
            tracing::info!(
                "Connected to OANDA account {} ({}), balance: {}",
                account.id,
                account.currency,
                account.balance
            );
        }
        Err(e) => {
            tracing::warn!("Failed to connect to OANDA: {}. Continuing anyway.", e);
        }
    }

    if !is_forex_market_open() {
        tracing::info!("Forex market is currently closed. Live prices will resume when the market opens (Sunday 5pm ET).")
    }

    // Create broadcast channel for price streaming
    let (price_tx, _) = broadcast::channel(256);

    // Build shared state
    let state = AppState {
        db: pool.clone(),
        config: config.clone(),
        oanda: oanda.clone(),
        live: Arc::new(LiveState::new()),
        price_tx: price_tx.clone(),
    };

    // Spawn the tick aggregator (subscribes to price stream, writes M1 candles to DB)
    let aggregator_rx = price_tx.subscribe();
    spawn_aggregator(aggregator_rx, state.db.clone());

    let evaluator_rx = price_tx.subscribe();
    spawn_live_evaluator(evaluator_rx, state.clone());

    // Spawn the OANDA price stream
    let stream_instruments: Vec<String> =
        DEFAULT_INSTRUMENTS.iter().map(|s| s.to_string()).collect();

    spawn_price_stream(state.oanda.clone(), stream_instruments, price_tx.clone());

    // Backfill historical candles (runs in background)
    let backfill_state = state.clone();
    tokio::spawn(async move {
        backfill_candles(&backfill_state.oanda, &backfill_state.db, 7).await;
    });

    // Build router
    let app = api::router()
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods(Any)
                .allow_headers(Any),
        )
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    // Start server
    let listener = TcpListener::bind(config.listen_addr()).await?;
    tracing::info!("Listening on {}", config.listen_addr());
    axum::serve(listener, app).await?;

    Ok(())
}
