mod account;
mod backtest;
mod candles;
pub mod evaluator;
mod health;
mod indicators;
mod live_strategies;
mod positions;
mod strategies;
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
        .route("/api/account", get(account::get_account))
        .route("/api/instruments", get(account::get_instruments))
        .route("/api/pricing", get(account::get_pricing))
        .route("/api/candles", get(candles::get_candles))
        .route("/api/open-trades", get(account::get_open_trades))
        .route("/api/evaluate/{granularity}", post(evaluator::evaluate))
        .route(
            "/api/indicators/{instrument}/{granularity}",
            get(indicators::get_indicators),
        )
        .route("/api/positions/{trade_id}", delete(positions::remove_in_memory_position))
        // Backtest
        .route("/api/backtest/run", post(backtest::run_grid_search))
        .route(
            "/api/backtest/backfill",
            post(backtest::backfill_historical),
        )
        .route("/api/backtest/results", get(backtest::get_backtest_results))
        .route(
            "/api/backtest/runs/{id}/trades",
            get(backtest::get_backtest_trades),
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
            "/api/live/strategies/{id}",
            delete(live_strategies::delete_live_strategy),
        )
        .route(
            "/api/live/deploy/{id}",
            post(live_strategies::deploy_from_backtest),
        )
        .route("/api/live/trades", get(live_strategies::get_live_trades))
        .route("/api/live/config", get(live_strategies::get_trading_config))
        .route(
            "/api/live/config",
            put(live_strategies::update_trading_config),
        )
        // Legacy strategies (can remove later)
        .route("/api/strategies", get(strategies::list_strategies))
        .route("/api/strategies", post(strategies::create_strategy))
        .route("/api/strategies/{id}", get(strategies::get_strategy))
        .route("/api/strategies/{id}", put(strategies::update_strategy))
        .route(
            "/api/strategies/{id}/toggle",
            post(strategies::toggle_strategy),
        )
        .route("/api/strategies/{id}", delete(strategies::delete_strategy))
        // WebSocket
        .route("/ws/prices", get(ws::ws_prices))
}
