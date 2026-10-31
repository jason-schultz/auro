mod account;
mod brokers;
mod candles;
mod financing;
mod health;
mod indicators;
mod instruments;
mod live_strategies;
mod massive;
mod options;
mod pipeline;
mod portfolio;
mod positions;
mod questrade;
mod rules;
mod share_alerts;
mod signal_preview;
mod strategy_report;
mod wealthsimple;
mod ws;

use axum::routing::{delete, get, post, put};
use axum::Router;

use crate::state::AppState;

/// Every route belongs to exactly one of three groups, and these two
/// functions are the only routers the binaries serve:
///
/// - `live_only`: trading and live state — orders, rules, positions, the
///   price socket, broker calls, anything that reads the in-memory buffers.
/// - `tester_only`: backtests, pipeline stages, reports, grids, the
///   Together replay. Heavy CPU over years of bars; never on the live
///   process, so testing can't starve the price stream (AGENTS.md).
/// - `shared`: cheap read-only lookups either process may answer.
///
/// A new route goes into one of those three groups; there is nowhere else
/// to add it. `tests/router_modes.rs` checks the split.
pub fn live_router() -> Router<AppState> {
    shared().merge(live_only())
}

/// See `live_router`.
pub fn tester_router() -> Router<AppState> {
    shared().merge(tester_only())
}

fn shared() -> Router<AppState> {
    Router::new()
        .route("/api/health", get(health::health))
        .route("/api/candles", get(candles::get_candles))
}

fn tester_only() -> Router<AppState> {
    Router::new()
        // Strategy reads over its whole history (builder, strategy page,
        // drift check, Together)
        .route(
            "/api/strategy/signal-preview",
            post(signal_preview::preview_signals),
        )
        .route("/api/strategy/report", post(strategy_report::equity_report))
        .route(
            "/api/strategy/sensitivity",
            post(strategy_report::sensitivity),
        )
        .route("/api/strategy/portfolio", post(portfolio::portfolio))
        .route(
            "/api/strategy/trades",
            post(strategy_report::backtest_trades),
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
            "/api/pipeline/parameter_stability",
            post(pipeline::run_pipeline_parameter_stability),
        )
        .route(
            "/api/pipeline/holdout",
            post(pipeline::run_pipeline_holdout),
        )
}

fn live_only() -> Router<AppState> {
    Router::new()
        .route(
            "/api/debug/positions",
            get(live_strategies::debug_positions),
        )
        .route("/api/debug/buffers", get(live_strategies::debug_buffers))
        .route("/api/health/live", get(health::live_health))
        .route("/api/account", get(account::get_account))
        .route("/api/instruments", get(account::get_instruments))
        .route("/api/instruments/enrich", post(instruments::enrich))
        .route("/api/pricing", get(account::get_pricing))
        .route("/api/candles/backfill", post(candles::backfill))
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
        // Spends a Questrade refresh token: never on the tester.
        .route("/api/questrade/connect", post(questrade::connect))
        .route("/api/questrade/candles", get(questrade::get_candles))
        .route("/api/questrade/quotes", get(questrade::get_quotes))
        // What each share-alert assignment says today; no orders
        .route("/api/share-alerts/evaluate", post(share_alerts::evaluate))
        .route("/api/questrade/symbols", get(questrade::get_symbols))
        .route(
            "/api/questrade/candles/persist",
            post(questrade::persist_candles),
        )
        .route(
            "/api/questrade/options/snapshot",
            post(questrade::snapshot_option_chain),
        )
        .route(
            "/api/questrade/options/quotes",
            post(questrade::quote_option_contracts),
        )
        // Massive (US equity bars, option contract history)
        .route(
            "/api/massive/candles/persist",
            post(massive::persist_candles),
        )
        .route(
            "/api/massive/dividends/persist",
            post(massive::persist_dividends),
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
