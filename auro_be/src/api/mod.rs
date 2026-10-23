mod account;
mod brokers;
mod candles;
mod financing;
mod health;
mod indicators;
mod live_strategies;
mod massive;
mod options;
mod pipeline;
mod positions;
mod questrade;
mod rules;
mod signal_preview;
mod wealthsimple;
mod ws;

use axum::routing::{delete, get, post, put};
use axum::Router;

use crate::state::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route(
            "/api/debug/positions",
            get(live_strategies::debug_positions),
        )
        .route("/api/debug/buffers", get(live_strategies::debug_buffers))
        .route("/api/health", get(health::health))
        .route("/api/health/live", get(health::live_health))
        .route("/api/account", get(account::get_account))
        .route("/api/instruments", get(account::get_instruments))
        .route("/api/pricing", get(account::get_pricing))
        .route("/api/candles", get(candles::get_candles))
        .route("/api/candles/backfill", post(candles::backfill))
        .route(
            "/api/strategy/signal-preview",
            post(signal_preview::preview_signals),
        )
        .route("/api/open-trades", get(account::get_open_trades))
        .route(
            "/api/indicators/{instrument}/{granularity}",
            get(indicators::get_indicators),
        )
        .route("/api/rules", post(rules::push_rules))
        .route(
            "/api/positions/{trade_id}",
            delete(positions::remove_in_memory_position),
        )
        // Pipeline
        .route(
            "/api/pipeline/backtest",
            post(pipeline::run_pipeline_backtest),
        )
        .route(
            "/api/pipeline/walk_forward",
            post(pipeline::run_pipeline_walk_forward),
        )
        .route(
            "/api/pipeline/monte_carlo",
            post(pipeline::run_pipeline_monte_carlo),
        )
        .route(
            "/api/pipeline/holdout",
            post(pipeline::run_pipeline_holdout),
        )
        // Live strategies
        .route(
            "/api/live/strategies",
            get(live_strategies::list_live_strategies),
        )
        .route(
            "/api/live/strategies",
            post(live_strategies::create_live_strategy),
        )
        .route(
            "/api/live/strategies/{id}",
            get(live_strategies::get_live_strategy),
        )
        .route(
            "/api/live/strategies/{id}",
            put(live_strategies::update_live_strategy),
        )
        .route(
            "/api/live/strategies/{id}/toggle",
            post(live_strategies::toggle_live_strategy),
        )
        .route(
            "/api/live/strategies/{id}/curator/auto",
            post(live_strategies::reset_live_strategy_curator_auto),
        )
        .route(
            "/api/live/strategies/{id}",
            delete(live_strategies::delete_live_strategy),
        )
        .route("/api/live/trades", get(live_strategies::get_live_trades))
        .route(
            "/api/live/trades/{id}",
            get(live_strategies::get_live_trade_detail),
        )
        .route("/api/live/config", get(live_strategies::get_trading_config))
        .route(
            "/api/live/config",
            put(live_strategies::update_trading_config),
        )
        // Brokers
        .route("/api/brokers", get(brokers::list_brokers))
        .route("/api/brokers/wealthsimple", get(wealthsimple::get_accounts))
        .route(
            "/api/brokers/wealthsimple",
            put(wealthsimple::save_accounts),
        )
        .route(
            "/api/brokers/wealthsimple/refresh-prices",
            post(wealthsimple::refresh_prices),
        )
        // Questrade
        .route("/api/financing/snapshot", post(financing::snapshot))
        .route("/api/questrade/status", get(questrade::status))
        .route("/api/questrade/candles", get(questrade::get_candles))
        .route("/api/questrade/quotes", get(questrade::get_quotes))
        .route("/api/questrade/symbols", get(questrade::get_symbols))
        .route(
            "/api/questrade/candles/persist",
            post(questrade::persist_candles),
        )
        // Massive (US equity bars)
        .route(
            "/api/massive/candles/persist",
            post(massive::persist_candles),
        )
        .route(
            "/api/massive/options/contracts/sync",
            post(massive::sync_option_contracts),
        )
        .route(
            "/api/massive/options/bars/persist",
            post(massive::persist_option_bars),
        )
        // Options what-if (pure math; spot/rate defaults from storage)
        .route("/api/options/scenarios", post(options::scenarios))
        // WebSocket
        .route("/ws/prices", get(ws::ws_prices))
}
