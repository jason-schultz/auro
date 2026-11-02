pub mod api;
pub mod brokers;
pub mod config;
pub mod db;
pub mod engine;
pub mod error;
pub mod secrets;
pub mod state;

use std::collections::HashMap;
use std::sync::Arc;

use crate::brokers::connections::{self, Connections};
use crate::brokers::massive::client::MassiveClient;
use brokers::oanda::client::OandaClient;
use brokers::oanda::stream::run_price_stream;
use brokers::oanda::{is_forex_market_open, INSTRUMENTS};
use brokers::questrade::client::is_token_refused;
use brokers::questrade::client::QuestradeClient;
use brokers::questrade::link::{retry_until_connected, Connect, QuestradeLink};
use brokers::wealthsimple::client::WealthsimpleClient;
use config::{Config, Mode};
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
/// Each process logs to its own files (`logs/auro.*` live,
/// `logs/auro-tester.*` tester) so neither rotates over the other.
fn init_tracing(mode: Mode) -> tracing_appender::non_blocking::WorkerGuard {
    let prefix = match mode {
        Mode::Live => "auro",
        Mode::Tester => "auro-tester",
    };
    let file_appender = Builder::new()
        .filename_prefix(prefix)
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

/// Start one of the two processes. `auro` (src/main.rs) runs `Mode::Live`,
/// `auro-tester` (src/bin/auro-tester.rs) runs `Mode::Tester`.
pub async fn run(mode: Mode) -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    let _log_guard = init_tracing(mode);

    // The database comes first (from .env): the rest of the settings may be
    // stored in it, from Opus's Settings page, encrypted under
    // AURO_SECRETS_KEY. The live engine stores secrets (Questrade tokens),
    // so it needs the key; the tester only reads.
    let key = std::env::var("AURO_SECRETS_KEY")
        .ok()
        .filter(|k| !k.is_empty())
        .map(|k| secrets::SecretsKey::from_hex(&k))
        .transpose()
        .map_err(|e| anyhow::anyhow!(e))?;
    match (key, mode) {
        (Some(key), _) => secrets::install(key),
        (None, Mode::Live) => anyhow::bail!(
            "AURO_SECRETS_KEY is not set: the live engine keeps its tokens encrypted (openssl rand -hex 32, the same in Opus's settings)"
        ),
        (None, Mode::Tester) => {}
    }

    // Both processes check the schema; each sizes its own pool.
    let (database_url, pool_size) = Config::database_from_env(mode)?;
    let pool = db::create_pool(&database_url, pool_size, mode).await?;

    let stored = stored_settings(&pool).await?;
    let config = Config::from_stored(mode, &stored)
        .map_err(|e| anyhow::anyhow!("Failed to load config: {}", e))?;

    tracing::info!(
        "Starting Auro ({}) on {}",
        mode.as_str(),
        config.listen_addr()
    );

    let (state, app) = match mode {
        Mode::Live => (start_live(config.clone(), pool).await, api::live_router()),
        Mode::Tester => (tester_state(config.clone(), pool), api::tester_router()),
    };

    let app = app
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

/// The settings saved on Opus's Settings page, decrypted, by name. One that
/// won't open (another key, a damaged value) is left out with a warning,
/// so its `.env` value is used instead; an empty one is left out too.
pub(crate) async fn stored_settings(
    pool: &sqlx::PgPool,
) -> anyhow::Result<HashMap<String, String>> {
    let rows = db::repositories::settings::load_all(pool).await?;
    let mut stored = HashMap::new();
    for (name, value) in rows {
        match secrets::open(&name, &value) {
            Ok(plain) if !plain.is_empty() => {
                stored.insert(name, plain);
            }
            Ok(_) => {}
            Err(e) => tracing::warn!("{e}; using .env for {name} instead"),
        }
    }
    tracing::info!(
        "Settings from the database: {}",
        stored.keys().cloned().collect::<Vec<_>>().join(", ")
    );
    Ok(stored)
}

/// The tester's state: the database and nothing that talks to a broker.
/// No OANDA call, no Questrade token exchange (that would rotate the live
/// engine's token), no Massive client, no background task. The OANDA client
/// is inert: no tester route uses it.
fn tester_state(config: Config, pool: sqlx::PgPool) -> AppState {
    let oanda = OandaClient::new(
        &config.oanda_base_url,
        &config.oanda_stream_url,
        &config.oanda_api_key,
        &config.oanda_account_id,
    );
    let (price_tx, _) = broadcast::channel(1);

    AppState {
        db: pool.clone(),
        config,
        oanda,
        start_time: chrono::Utc::now(),
        live: Arc::new(LiveState::new()),
        price_tx,
        questrade: Arc::new(QuestradeLink::default()),
        wealthsimple: WealthsimpleClient::new(&pool),
        connections: Arc::new(Connections::default()),
    }
}

/// Connect the brokers, load live state and spawn every live task: price
/// stream, quote tracker, candle feed, account refresher, position sync,
/// instrument metadata reload.
async fn start_live(config: Config, pool: sqlx::PgPool) -> AppState {
    let oanda = OandaClient::new(
        &config.oanda_base_url,
        &config.oanda_stream_url,
        &config.oanda_api_key,
        &config.oanda_account_id,
    );

    let connections = Arc::new(Connections::default());
    let started = chrono::Utc::now();
    let oanda_check = match oanda.get_account().await {
        Ok(account) => {
            tracing::info!(
                "Connected to OANDA account {} ({}), balance: {}",
                account.id,
                account.currency,
                account.balance
            );
            (true, api::settings::oanda_answered(&account))
        }
        Err(e) => {
            tracing::warn!("Failed to connect to OANDA: {}. Continuing anyway.", e);
            (false, format!("OANDA didn't answer at startup: {e}"))
        }
    };
    connections.record_check(
        connections::OANDA,
        started,
        oanda_check.0,
        oanda_check.1,
        true,
    );

    if !is_forex_market_open() {
        tracing::info!(
            "Forex market is currently closed. Live prices will resume when the market opens (Sunday 5pm ET)."
        )
    }

    let (price_tx, _) = broadcast::channel(256);

    // A failed start retries the saved token in the background, and a new
    // token can be pasted on Opus's Accounts page; neither needs a restart.
    let questrade = Arc::new(QuestradeLink::default());
    match questrade
        .connect(QuestradeClient::connect(
            &pool,
            config.questrade_refresh_token.as_deref(),
        ))
        .await
    {
        Ok(Connect::Connected) => tracing::info!("Questrade connected."),
        Ok(_) => tracing::info!(
            "No Questrade token saved or configured; connect from the Accounts page."
        ),
        // A refused token won't become good again: only a new one helps.
        Err(e) if is_token_refused(&e) => tracing::warn!(
            "Questrade init error: {}. Continuing without Questrade; paste a new token on \
             the Accounts page.",
            e
        ),
        Err(e) => {
            tracing::warn!(
                "Questrade init error: {}. Continuing without Questrade; retrying the saved \
                 token in the background, or paste a new one on the Accounts page.",
                e
            );
            tokio::spawn(retry_until_connected(questrade.clone(), pool.clone()));
        }
    }

    if let Some(client) = match config.massive_api_key.as_deref() {
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
                connections.update(connections::MASSIVE, |status| {
                    status.in_use_since = Some(started);
                });
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
    } {
        connections.set_massive(client);
    }

    let state = AppState {
        db: pool.clone(),
        config: config.clone(),
        oanda: oanda.clone(),
        start_time: chrono::Utc::now(),
        live: Arc::new(LiveState::new()),
        price_tx: price_tx.clone(),
        questrade,
        wealthsimple: WealthsimpleClient::new(&pool),
        connections,
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
        spawn_supervised("stock feed", move || {
            engine::live::stock_feed::run_stock_feed(state.clone())
        });
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

    state
}
