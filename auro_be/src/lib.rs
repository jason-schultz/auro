pub mod api;
pub mod brokers;
pub mod config;
pub mod db;
pub mod engine;
pub mod error;
pub mod state;

use std::sync::Arc;

use crate::brokers::massive::client::MassiveClient;
use brokers::oanda::client::OandaClient;
use brokers::oanda::stream::run_price_stream;
use brokers::oanda::{is_forex_market_open, INSTRUMENTS};
use brokers::questrade::client::QuestradeClient;
use brokers::wealthsimple::client::WealthsimpleClient;
use config::Config;
use engine::live::account_cache::run_account_refresher;
use engine::live::candle_feed::run_candle_feed;
use engine::live::instrument_cache::load_instrument_metadata;
use engine::live::instrument_cache::run_metadata_reload;
use engine::live::position_sync::spawn_position_sync;
use engine::live::quotes::run_quote_tracker;
use engine::live::spawn_supervised;
use state::{AppState, LiveState};
use tokio::net::TcpListener;
use tokio::sync::broadcast;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing_appender::rolling::{Builder, Rotation};
use tracing_subscriber::fmt::writer::MakeWriterExt;
use tracing_subscriber::EnvFilter;

/// The returned guard flushes the file writer; it must live for the whole
/// process or file logging silently stops.
fn init_tracing() -> tracing_appender::non_blocking::WorkerGuard {
    let file_appender = Builder::new()
        .filename_prefix("auro")
        .filename_suffix("log")
        .rotation(Rotation::DAILY)
        .max_log_files(7)
        .build("logs")
        .expect("failed to create log file appender");

    let (file_writer, file_guard) = tracing_appender::non_blocking(file_appender);

    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("auro=debug,tower_http=debug")),
        )
        .with_writer(std::io::stdout.and(file_writer))
        .init();

    file_guard
}

pub async fn run() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    let _log_guard = init_tracing();

    let config = Config::from_env().map_err(|e| anyhow::anyhow!("Failed to load config: {}", e))?;

    tracing::info!("Starting Auro on {}", config.listen_addr());

    let pool = db::create_pool(&config.database_url).await?;

    let oanda = OandaClient::new(
        &config.oanda_base_url,
        &config.oanda_stream_url,
        &config.oanda_api_key,
        &config.oanda_account_id,
    );

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
        tracing::info!(
            "Forex market is currently closed. Live prices will resume when the market opens (Sunday 5pm ET)."
        )
    }

    let (price_tx, _) = broadcast::channel(256);

    let questrade =
        match QuestradeClient::connect(&pool, config.questrade_refresh_token.as_deref()).await {
            Ok(Some(client)) => {
                tracing::info!("Questrade connected.");
                Some(Arc::new(tokio::sync::Mutex::new(client)))
            }
            Ok(None) => {
                tracing::info!("No Questrade token configured; skipping.");
                None
            }
            Err(e) => {
                tracing::warn!("Questrade init error: {}. Continuing without Questrade.", e);
                None
            }
        };

    let massive = match config.massive_api_key.as_deref() {
        Some(key) => match MassiveClient::new(
            &config.massive_base_url,
            key,
            config.massive_calls_per_minute,
        ) {
            Ok(client) => {
                tracing::info!(
                    "Massive market data configured ({}).",
                    config.massive_base_url
                );
                Some(client)
            }
            Err(e) => {
                tracing::warn!("Massive init error: {}. Continuing without Massive.", e);
                None
            }
        },
        None => {
            tracing::info!("No Massive API key configured; US stock bars disabled.");
            None
        }
    };

    let state = AppState {
        db: pool.clone(),
        config: config.clone(),
        oanda: oanda.clone(),
        start_time: chrono::Utc::now(),
        live: Arc::new(LiveState::new()),
        price_tx: price_tx.clone(),
        questrade,
        wealthsimple: WealthsimpleClient::new(&pool),
        massive,
    };

    let instrument_metadata = load_instrument_metadata(&state.oanda, &state.db).await;
    {
        let mut cache = state.live.instrument_metadata.write().await;
        *cache = instrument_metadata;
    }

    // Long-lived tasks run supervised: one that stops or panics starts again.
    {
        let (state, tx) = (state.clone(), price_tx.clone());
        spawn_supervised("quote tracker", move || {
            run_quote_tracker(tx.subscribe(), state.clone())
        });
    }
    {
        let state = state.clone();
        spawn_supervised("candle feed", move || run_candle_feed(state.clone()));
    }
    {
        let state = state.clone();
        spawn_supervised("account refresher", move || {
            run_account_refresher(state.clone())
        });
    }
    spawn_position_sync(state.clone());
    {
        let state = state.clone();
        spawn_supervised("instrument metadata reload", move || {
            run_metadata_reload(state.clone())
        });
    }

    let stream_instruments: Vec<String> = INSTRUMENTS.iter().map(|s| s.to_string()).collect();
    {
        let (oanda, tx) = (state.oanda.clone(), price_tx.clone());
        spawn_supervised("price stream", move || {
            run_price_stream(oanda.clone(), stream_instruments.clone(), tx.clone())
        });
    }

    let app = api::router()
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods(Any)
                .allow_headers(Any),
        )
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let listener = TcpListener::bind(config.listen_addr()).await?;
    tracing::info!("Listening on {}", config.listen_addr());
    axum::serve(listener, app).await?;

    Ok(())
}
