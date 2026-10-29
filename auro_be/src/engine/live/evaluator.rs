use std::collections::HashMap;
use std::sync::Arc;

use crate::brokers::oanda::client::OandaClient;
use crate::db::repositories::live_trades::{
    self as live_trades_repo, ClosedLiveTrade, NewLiveTrade,
};
use crate::db::repositories::{live_queries, live_strategies as live_strategies_repo};
use crate::engine::indicators;
use crate::engine::rules::{entry_gate_report, Rules};
use crate::engine::strategy::{
    self as strategy_mod, EntrySignal, ExitSignal, SizingConfig, Strategy,
};
use crate::engine::types::{
    Direction, Granularity, LiveStrategy, OpenPosition, SignalAction, SignalReport, StopLossState,
};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

use super::account_cache;
use super::format_price;
use super::sizing::{size_entry, SizedEntry};
use crate::engine::types::CandleBuffer;

fn parse_trade_realized_pl(transaction: &serde_json::Value, trade_id: &str) -> Option<f64> {
    let closed = transaction.get("tradesClosed")?.as_array()?;
    closed.iter().find_map(|entry| {
        let id = entry.get("tradeID").and_then(|v| v.as_str())?;
        if id != trade_id {
            return None;
        }
        entry
            .get("realizedPL")
            .and_then(|v| v.as_str())
            .and_then(|s| s.parse::<f64>().ok())
    })
}

async fn extract_realized_pl(
    oanda: &OandaClient,
    close_response: &serde_json::Value,
    trade_id: &str,
) -> Option<f64> {
    if let Some(fill_tx) = close_response.get("orderFillTransaction") {
        if let Some(pl) = parse_trade_realized_pl(fill_tx, trade_id) {
            return Some(pl);
        }

        if let Some(tx_id) = fill_tx.get("id").and_then(|v| v.as_str()) {
            if let Ok(tx_resp) = oanda.get_transaction(tx_id).await {
                let tx = tx_resp.get("transaction").unwrap_or(&tx_resp);
                if let Some(pl) = parse_trade_realized_pl(tx, trade_id) {
                    return Some(pl);
                }
            }
        }
    }

    None
}

fn entry_rejected(strategy: &LiveStrategy, price: f64, reason: String) -> SignalReport {
    SignalReport {
        strategy_id: strategy.id,
        strategy_type: strategy.strategy_type.clone(),
        instrument: strategy.instrument.clone(),
        granularity: strategy.granularity,
        action: SignalAction::EntryRejected,
        price,
        reason,
        oanda_trade_id: None,
    }
}

pub(crate) fn position_key_deltas(
    before: &HashMap<String, OpenPosition>,
    after: &HashMap<String, OpenPosition>,
) -> (Vec<String>, Vec<(String, OpenPosition)>) {
    let removed: Vec<String> = before
        .keys()
        .filter(|k| !after.contains_key(*k))
        .cloned()
        .collect();

    let added: Vec<(String, OpenPosition)> = after
        .iter()
        .filter(|(k, _)| !before.contains_key(*k))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();

    (removed, added)
}

/// Which decisions an evaluation may take.
///
/// A bar that reaches the feed late (more than one bar after it closed) is
/// stale for entries: the setup it shows may be long gone. Its exit rules
/// still matter, because the backtest would have exited on that bar and an
/// open position must not outlive its signal just because OANDA was slow.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum EvalScope {
    /// Entries and exits: the bar just closed.
    Full,
    /// Exits only: a catch-up bar, evaluated for open positions.
    ExitsOnly,
}

/// What an evaluation is allowed to do: the rules Opus pushed and the scope.
#[derive(Debug, Clone, Copy)]
pub(crate) struct EvalContext<'a> {
    pub rules: &'a Rules,
    pub scope: EvalScope,
}

pub(crate) async fn evaluate_and_apply(
    state: &AppState,
    instrument: &str,
    granularity: Granularity,
    buffer: &CandleBuffer,
    current_price: f64,
    scope: EvalScope,
) -> AppResult<Vec<SignalReport>> {
    let key = (instrument.to_string(), granularity);

    let eval_lock = {
        let locks = state.live.eval_locks.read().await;
        if let Some(existing) = locks.get(&key) {
            existing.clone()
        } else {
            drop(locks);
            let mut locks = state.live.eval_locks.write().await;
            locks
                .entry(key.clone())
                .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(())))
                .clone()
        }
    };

    let _guard = eval_lock.lock().await;

    let rules_snapshot = state.live.rules.read().await.clone();
    let before_positions = state.live.open_positions.read().await.clone();
    let mut working_positions = before_positions.clone();

    let reports = evaluate_strategies(
        state,
        instrument,
        &granularity,
        buffer,
        current_price,
        &mut working_positions,
        EvalContext {
            rules: &rules_snapshot,
            scope,
        },
    )
    .await?;

    let (removed, added) = position_key_deltas(&before_positions, &working_positions);
    if !removed.is_empty() || !added.is_empty() {
        let mut open_positions = state.live.open_positions.write().await;
        for trade_id in removed {
            open_positions.remove(&trade_id);
        }
        for (trade_id, position) in added {
            open_positions.insert(trade_id, position);
        }
    }

    Ok(reports)
}

pub(crate) async fn evaluate_strategies(
    state: &AppState,
    instrument: &str,
    granularity: &Granularity,
    buffer: &CandleBuffer,
    current_price: f64,
    open_positions: &mut HashMap<String, OpenPosition>,
    ctx: EvalContext<'_>,
) -> AppResult<Vec<SignalReport>> {
    // Entries need the kill switch open; exits never wait on it. A kill
    // switch that also blocked exits would leave open positions to their
    // OANDA stops alone, the opposite of what pulling it means. The same
    // holds when the flag cannot be read: no entries this bar, exits as usual.
    let entries_allowed = match ctx.scope {
        EvalScope::ExitsOnly => false,
        EvalScope::Full => match live_queries::is_trading_enabled(&state.db).await {
            Ok(enabled) => enabled,
            Err(e) => {
                tracing::error!(
                    "trading_enabled unreadable; no entries this bar for {instrument} {granularity}: {e}"
                );
                false
            }
        },
    };

    // Disabled strategies are listed too: a strategy switched off with a
    // position open still has to take its exit.
    let strategies: Vec<LiveStrategy> = live_strategies_repo::list_for_instrument_granularity(
        &state.db,
        instrument,
        granularity.as_str(),
    )
    .await?;

    let mut reports: Vec<SignalReport> = Vec::new();

    for strategy in &strategies {
        // All live strategies use the composite shape. `strategy_type` is a
        // lineage label (mean_reversion/trend_following/etc.), not a parse key.
        let composite: Strategy = match serde_json::from_value(strategy.parameters.clone()) {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(
                    "[SKIP] composite parse failure for {} {}: {}",
                    strategy.instrument,
                    strategy.granularity,
                    e
                );
                continue;
            }
        };

        let has_position = open_positions
            .values()
            .any(|p| p.strategy_id == strategy.id);

        if has_position {
            let exit_reports = evaluate_exit(
                state,
                strategy,
                &composite,
                current_price,
                buffer,
                open_positions,
            )
            .await?;
            reports.extend(exit_reports);
        } else if !entries_allowed || !strategy.enabled {
            continue;
        } else if let Some(entry_report) = evaluate_entry(
            state,
            strategy,
            &composite,
            current_price,
            buffer,
            open_positions,
            ctx.rules,
        )
        .await?
        {
            reports.push(entry_report);
        }
    }

    *state.live.last_evaluator_run.write().await = Some(chrono::Utc::now());

    Ok(reports)
}

async fn evaluate_entry(
    state: &AppState,
    strategy: &LiveStrategy,
    composite: &Strategy,
    current_price: f64,
    buffer: &CandleBuffer,
    open_positions: &mut HashMap<String, OpenPosition>,
    rules: &Rules,
) -> AppResult<Option<SignalReport>> {
    let candles = &buffer.candles;
    let warmup = composite.warmup();
    if candles.len() < warmup {
        tracing::info!(
            "[STATUS] composite {} {} | buffer {}/{} — waiting for data",
            strategy.instrument,
            strategy.granularity,
            candles.len(),
            warmup,
        );
        return Ok(None);
    }

    let Some(ports) = composite.compute_ports(candles) else {
        return Ok(None);
    };

    tracing::info!(
        "[STATUS] composite {} {} | ports={:?} | buf={}",
        strategy.instrument,
        strategy.granularity,
        ports,
        candles.len(),
    );

    let direction = match composite.evaluate_entry(&ports) {
        EntrySignal::Long => Direction::Long,
        EntrySignal::Short => Direction::Short,
        EntrySignal::None => return Ok(None),
    };

    tracing::info!(
        "[SIGNAL] Composite {:?} entry on {} ({}): price={:.5}",
        direction,
        strategy.instrument,
        strategy.granularity,
        current_price,
    );

    if let Some(gated) = entry_gate_report(rules, strategy, current_price) {
        return Ok(Some(gated));
    }

    let Some(sl_price) =
        strategy_mod::compute_stop_price(composite, current_price, direction, candles)
    else {
        tracing::warn!(
            "[SKIP ENTRY] composite {} {} — stop config could not compute SL (component-derived stop returned None)",
            strategy.instrument,
            strategy.granularity,
        );
        return Ok(None);
    };

    let SizingConfig::RiskPct {
        pct: risk_pct,
        max_notional_pct,
    } = composite.sizing;

    if let Some(breach) =
        rules.account_limit_breach(&strategy.instrument, risk_pct, open_positions.values())
    {
        tracing::info!(
            "[GATED] {} {} entry blocked by account limit: {}",
            strategy.instrument,
            strategy.granularity,
            breach
        );
        return Ok(Some(entry_rejected(strategy, current_price, breach)));
    }

    let sized = match size_entry(
        state,
        &strategy.instrument,
        direction,
        risk_pct,
        max_notional_pct,
        current_price,
        sl_price,
    )
    .await
    {
        Ok(sized) => sized,
        Err(reason) => {
            return Ok(Some(entry_rejected(
                strategy,
                current_price,
                format!("sizing_skip:{}", reason.as_str()),
            )))
        }
    };

    let indicators_at_entry = serde_json::json!({
        "strategy_version": composite.version,
        "components": composite.components.keys().collect::<Vec<_>>(),
        "ports": ports,
        "adx": indicators::adx(candles, 14),
    });
    let (_, regime_reason) = rules.decision(&strategy.id);
    let signal_bar = candles.last();
    let entry = PendingEntry {
        direction,
        sized,
        current_price,
        expected_entry_price: signal_bar.map(|c| c.entry_fill_price(direction)),
        entry_spread: signal_bar.and_then(|c| c.spread()),
        sl_price,
        entry_reason: format!("Composite {:?} entry", direction),
        indicators_at_entry,
        regime_at_entry: regime_reason.unwrap_or("unknown").to_string(),
        entry_time: candles
            .last()
            .map(|c| c.time)
            .unwrap_or_else(chrono::Utc::now),
    };

    execute_entry(state, strategy, entry, open_positions).await
}

/// A fully decided entry, waiting only on the OANDA fill.
struct PendingEntry {
    direction: Direction,
    sized: SizedEntry,
    current_price: f64,
    /// The backtest's assumed fill for the decision bar, and its spread, so
    /// live slippage can be measured against it.
    expected_entry_price: Option<f64>,
    entry_spread: Option<f64>,
    sl_price: f64,
    entry_reason: String,
    indicators_at_entry: serde_json::Value,
    regime_at_entry: String,
    entry_time: chrono::DateTime<chrono::Utc>,
}

async fn execute_entry(
    state: &AppState,
    strategy: &LiveStrategy,
    entry: PendingEntry,
    open_positions: &mut HashMap<String, OpenPosition>,
) -> AppResult<Option<SignalReport>> {
    let sl_str = format_price(state, &strategy.instrument, entry.sl_price).await;

    let resp = match state
        .oanda
        .create_market_order(&strategy.instrument, &entry.sized.units, &sl_str)
        .await
    {
        Ok(resp) => resp,
        Err(e) => {
            tracing::error!(
                "[ORDER FAILED] {} {} ({}): {}",
                entry.direction,
                strategy.instrument,
                strategy.granularity,
                e
            );
            return Ok(None);
        }
    };

    let Some(trade_id) = resp["orderFillTransaction"]["tradeOpened"]["tradeID"]
        .as_str()
        .map(str::to_string)
    else {
        tracing::error!(
            "[ORDER FAILED] {} {} ({}) missing tradeID in OANDA response; skipping in-memory/DB insert",
            entry.direction,
            strategy.instrument,
            strategy.granularity,
        );
        return Ok(None);
    };

    let Some(fill_price) = entry_fill_price(&state.oanda, &resp, &trade_id).await else {
        return abandon_untracked_trade(
            state,
            strategy,
            &trade_id,
            &entry,
            entry.current_price,
            "fill_price_unknown",
            open_positions,
        )
        .await;
    };

    tracing::info!(
        "[TRADE] Opened {} {} ({}) units={} @ {:.5}, SL={}, trade_id={}",
        entry.direction,
        strategy.instrument,
        strategy.granularity,
        entry.sized.units,
        fill_price,
        sl_str,
        trade_id
    );

    let new_trade = NewLiveTrade {
        live_strategy_id: strategy.id,
        oanda_trade_id: &trade_id,
        instrument: &strategy.instrument,
        direction: entry.direction,
        units: &entry.sized.units,
        entry_price: fill_price,
        stop_loss_price: entry.sl_price,
        entry_reason: &entry.entry_reason,
        indicators_at_entry: &entry.indicators_at_entry,
        regime_at_entry: &entry.regime_at_entry,
        sizing_metadata: &serde_json::to_value(&entry.sized.metadata)
            .map_err(|e| AppError::Internal(format!("sizing metadata serialization: {e}")))?,
        signal_price: entry.current_price,
        expected_entry_price: entry.expected_entry_price,
        entry_spread: entry.entry_spread,
    };
    // The row is the audit trail and what a restart rebuilds positions from,
    // so the trade is tracked in memory only once the row exists.
    if let Err(e) = persist_open_trade(&state.db, &new_trade).await {
        tracing::error!(
            "[TRADE] failed to persist live_trades row for trade_id={} after {} attempts: {}",
            trade_id,
            PERSIST_ATTEMPTS,
            e
        );
        return abandon_untracked_trade(
            state,
            strategy,
            &trade_id,
            &entry,
            fill_price,
            "persist_failed",
            open_positions,
        )
        .await;
    }

    open_positions.insert(
        trade_id.clone(),
        OpenPosition {
            strategy_id: strategy.id,
            trade_id: trade_id.clone(),
            instrument: strategy.instrument.clone(),
            granularity: strategy.granularity,
            direction: entry.direction,
            entry_price: fill_price,
            entry_time: entry.entry_time,
            units: entry.sized.units.clone(),
            stop_loss_state: StopLossState::NotApplicable,
            worst_price: fill_price,
            best_price: fill_price,
            strategy_type: strategy.strategy_type.clone(),
        },
    );

    spawn_account_refresh(state);

    let action = match entry.direction {
        Direction::Long => SignalAction::OpenedLong,
        Direction::Short => SignalAction::OpenedShort,
    };

    Ok(Some(SignalReport {
        strategy_id: strategy.id,
        strategy_type: strategy.strategy_type.clone(),
        instrument: strategy.instrument.clone(),
        granularity: strategy.granularity,
        action,
        price: entry.current_price,
        reason: entry.entry_reason,
        oanda_trade_id: Some(trade_id),
    }))
}

/// Insert attempts before an opened trade is treated as untrackable.
const PERSIST_ATTEMPTS: u32 = 3;
const PERSIST_RETRY_DELAY: std::time::Duration = std::time::Duration::from_millis(250);

async fn persist_open_trade(
    pool: &sqlx::PgPool,
    trade: &NewLiveTrade<'_>,
) -> Result<(), sqlx::Error> {
    let mut attempt = 1;
    loop {
        match live_trades_repo::insert_open_trade(pool, trade).await {
            Ok(()) => return Ok(()),
            Err(e) if attempt < PERSIST_ATTEMPTS => {
                tracing::warn!(
                    "[TRADE] live_trades insert attempt {attempt} failed for trade_id={}: {e}",
                    trade.oanda_trade_id
                );
                attempt += 1;
                tokio::time::sleep(PERSIST_RETRY_DELAY).await;
            }
            Err(e) => return Err(e),
        }
    }
}

/// The price OANDA filled the opening order at: from the fill transaction,
/// or from the trade itself when the fill omits it. `None` means OANDA could
/// not say, and the caller must not invent one.
async fn entry_fill_price(
    oanda: &OandaClient,
    order_response: &serde_json::Value,
    trade_id: &str,
) -> Option<f64> {
    if let Some(price) = parse_price(&order_response["orderFillTransaction"]["price"]) {
        return Some(price);
    }
    tracing::warn!(
        "[TRADE] fill transaction for trade_id={trade_id} has no price; looking the trade up"
    );
    match oanda.get_trade(trade_id).await {
        Ok(trade) => parse_price(&trade["trade"]["price"]),
        Err(e) => {
            tracing::error!("[TRADE] trade lookup failed for trade_id={trade_id}: {e}");
            None
        }
    }
}

/// The price OANDA closed a trade at, from the close fill or the closed
/// trade's average close price. `None` is recorded as an unknown fill.
async fn exit_fill_price(
    oanda: &OandaClient,
    close_response: &serde_json::Value,
    trade_id: &str,
) -> Option<f64> {
    if let Some(price) = parse_price(&close_response["orderFillTransaction"]["price"]) {
        return Some(price);
    }
    tracing::warn!(
        "[TRADE CLOSED] close fill for trade_id={trade_id} has no price; looking the trade up"
    );
    match oanda.get_trade(trade_id).await {
        Ok(trade) => parse_price(&trade["trade"]["averageClosePrice"]),
        Err(e) => {
            tracing::error!("[TRADE CLOSED] trade lookup failed for trade_id={trade_id}: {e}");
            None
        }
    }
}

fn parse_price(value: &serde_json::Value) -> Option<f64> {
    value.as_str().and_then(|p| p.parse::<f64>().ok())
}

/// A trade is open at OANDA but cannot be tracked (no fill price, or no
/// `live_trades` row). An untracked position is the one thing the engine
/// must never hold, so close it. If even the close fails, keep it in memory
/// so this process manages it, and say loudly that a restart would lose it.
async fn abandon_untracked_trade(
    state: &AppState,
    strategy: &LiveStrategy,
    trade_id: &str,
    entry: &PendingEntry,
    price: f64,
    why: &str,
    open_positions: &mut HashMap<String, OpenPosition>,
) -> AppResult<Option<SignalReport>> {
    match state.oanda.close_trade(trade_id, None).await {
        Ok(_) => {
            tracing::error!(
                "[UNTRACKED] closed trade_id={} on {} right after opening: {}",
                trade_id,
                strategy.instrument,
                why
            );
            spawn_account_refresh(state);
            Ok(Some(entry_rejected(
                strategy,
                price,
                format!("{why}:closed_untracked_trade"),
            )))
        }
        Err(e) => {
            tracing::error!(
                "[UNTRACKED] trade_id={} on {} is OPEN at OANDA with no live_trades row and could not be closed ({}): {}. Managed in memory only; a restart loses it. Close it by hand.",
                trade_id,
                strategy.instrument,
                why,
                e
            );
            open_positions.insert(
                trade_id.to_string(),
                OpenPosition {
                    strategy_id: strategy.id,
                    trade_id: trade_id.to_string(),
                    instrument: strategy.instrument.clone(),
                    granularity: strategy.granularity,
                    direction: entry.direction,
                    entry_price: price,
                    entry_time: entry.entry_time,
                    units: entry.sized.units.clone(),
                    stop_loss_state: StopLossState::NotApplicable,
                    worst_price: price,
                    best_price: price,
                    strategy_type: strategy.strategy_type.clone(),
                },
            );
            Ok(Some(entry_rejected(
                strategy,
                price,
                format!("{why}:untracked_trade_left_open"),
            )))
        }
    }
}

fn spawn_account_refresh(state: &AppState) {
    let state = state.clone();
    tokio::spawn(async move {
        account_cache::refresh_once(&state).await;
    });
}

async fn evaluate_exit(
    state: &AppState,
    strategy: &LiveStrategy,
    composite: &Strategy,
    current_price: f64,
    buffer: &CandleBuffer,
    open_positions: &mut HashMap<String, OpenPosition>,
) -> AppResult<Vec<SignalReport>> {
    let positions_for_strategy: Vec<OpenPosition> = open_positions
        .values()
        .filter(|p| p.strategy_id == strategy.id)
        .cloned()
        .collect();

    let Some(first) = positions_for_strategy.first() else {
        return Ok(vec![]);
    };

    let Some(ports) = composite.compute_ports(&buffer.candles) else {
        return Ok(vec![]);
    };
    let signal_exit = matches!(
        composite.evaluate_exit(&ports, first.direction == Direction::Long),
        ExitSignal::Exit
    );

    let mut reports = Vec::<SignalReport>::new();

    for pos in &positions_for_strategy {
        let bars_held = buffer
            .candles
            .iter()
            .filter(|c| c.time > pos.entry_time)
            .count();
        let time_stop_reason = composite
            .max_hold_bars
            .filter(|limit| bars_held >= *limit)
            .map(|limit| format!("TimeStop (bars_held={} max_hold_bars={})", bars_held, limit));

        let close_reason = match time_stop_reason {
            Some(reason) => reason,
            None if signal_exit => format!("CompositeExit (ports={:?})", ports),
            None => continue,
        };

        tracing::info!(
            "[EXIT SIGNAL] {} on {} ({}): {}",
            pos.direction,
            pos.instrument,
            strategy.granularity,
            close_reason
        );

        let resp = match state.oanda.close_trade(&pos.trade_id, None).await {
            Ok(resp) => resp,
            Err(e) => {
                tracing::error!("[CLOSE FAILED] {} {}: {}", pos.direction, pos.instrument, e);
                continue;
            }
        };

        let fill_price = exit_fill_price(&state.oanda, &resp, &pos.trade_id).await;
        let realized_pl = extract_realized_pl(&state.oanda, &resp, &pos.trade_id).await;
        let pnl = fill_price.map(|fill| match pos.direction {
            Direction::Long => (fill - pos.entry_price) / pos.entry_price,
            Direction::Short => (pos.entry_price - fill) / pos.entry_price,
        });

        match (fill_price, pnl) {
            (Some(fill), Some(pnl)) => tracing::info!(
                "[TRADE CLOSED] {} {} ({}) @ {:.5}, PnL={:.4}%, reason={}",
                pos.direction,
                pos.instrument,
                strategy.granularity,
                fill,
                pnl * 100.0,
                close_reason
            ),
            _ => tracing::error!(
                "[TRADE CLOSED] {} {} ({}) trade_id={} closed but OANDA gave no fill price; recorded as unknown, reason={}",
                pos.direction,
                pos.instrument,
                strategy.granularity,
                pos.trade_id,
                close_reason
            ),
        }

        let decision_bar = buffer.candles.last();
        let closed = ClosedLiveTrade {
            oanda_trade_id: &pos.trade_id,
            exit_price: fill_price,
            pnl_percent: pnl,
            realized_pl,
            exit_reason: &close_reason,
            stop_loss_state_at_close: pos.stop_loss_state.as_str(),
            expected_exit_price: decision_bar.map(|c| c.exit_fill_price(pos.direction)),
            exit_spread: decision_bar.and_then(|c| c.spread()),
        };
        if let Err(e) = live_trades_repo::mark_closed(&state.db, &closed).await {
            tracing::error!(
                "[TRADE CLOSED] failed to persist close for trade_id={}: {}",
                pos.trade_id,
                e
            );
        }

        spawn_account_refresh(state);
        open_positions.remove(&pos.trade_id);

        let action = match pos.direction {
            Direction::Long => SignalAction::ClosedLong,
            Direction::Short => SignalAction::ClosedShort,
        };
        reports.push(SignalReport {
            strategy_id: strategy.id,
            strategy_type: strategy.strategy_type.clone(),
            instrument: pos.instrument.clone(),
            granularity: strategy.granularity,
            action,
            price: current_price,
            reason: close_reason,
            oanda_trade_id: Some(pos.trade_id.clone()),
        });
    }

    Ok(reports)
}

#[cfg(test)]
mod tests {
    use super::*;

    use axum::extract::State;
    use axum::routing::{get, post, put};
    use axum::{Json, Router};
    use chrono::{Duration, Utc};
    use uuid::Uuid;

    use crate::engine::live::account_cache::AccountSnapshot;
    use crate::engine::live::instrument_cache::InstrumentMeta;
    use crate::engine::types::{Candle, OHLC};
    use crate::state::LastQuote;

    /// Synthetic instrument: quote currency USD matches the test account's
    /// home currency, so no FX conversion is involved.
    const INSTRUMENT: &str = "TEST_USD";

    fn tf_parameters(name: &str, stop_pct: f64) -> serde_json::Value {
        serde_json::json!({
            "strategy_id": null,
            "strategy_name": name,
            "version": "v1_composite",
            "instrument": INSTRUMENT,
            "granularity": "H1",
            "components": {
                "tf": {"type": "TrendFollowing", "params": {"fast_period": 2, "slow_period": 3, "ma_type": "sma"}}
            },
            "entry": {"long": "tf.bullish_cross", "short": "tf.bearish_cross"},
            "exit": {"long": "tf.bearish_cross", "short": "tf.bullish_cross"},
            "stop": {"type": "FixedPct", "params": {"pct": stop_pct}},
            "sizing": {"type": "RiskPct", "params": {"pct": 0.01}}
        })
    }

    fn buffer_from_closes(closes: &[f64]) -> CandleBuffer {
        let mut buffer = CandleBuffer::new(16);
        let base = Utc::now();
        for (idx, close) in closes.iter().enumerate() {
            buffer.push(Candle {
                time: base + Duration::minutes(idx as i64),
                mid: OHLC {
                    open: *close,
                    high: *close,
                    low: *close,
                    close: *close,
                },
                volume: 1,
                bid: None,
                ask: None,
            });
        }
        buffer
    }

    /// What the mock OANDA answers: fill prices on the order and close fills
    /// (`None` leaves the price out, as a degraded response would), and the
    /// body served for a trade lookup.
    #[derive(Clone)]
    struct MockOanda {
        order_fill_price: Option<&'static str>,
        close_fill_price: Option<&'static str>,
        trade: serde_json::Value,
    }

    impl MockOanda {
        fn healthy() -> Self {
            Self {
                order_fill_price: Some("4.00000"),
                close_fill_price: Some("0.50000"),
                trade: serde_json::json!({}),
            }
        }
    }

    /// Mock OANDA order/close/trade endpoints; returns the base URL and the
    /// server task.
    async fn mock_oanda_with(cfg: MockOanda) -> (String, tokio::task::JoinHandle<()>) {
        async fn order(State(cfg): State<MockOanda>) -> Json<serde_json::Value> {
            let mut fill = serde_json::json!({
                "tradeOpened": {"tradeID": format!("t-{}", Uuid::new_v4())}
            });
            if let Some(price) = cfg.order_fill_price {
                fill["price"] = serde_json::json!(price);
            }
            Json(serde_json::json!({ "orderFillTransaction": fill }))
        }
        async fn close(State(cfg): State<MockOanda>) -> Json<serde_json::Value> {
            let mut fill = serde_json::json!({
                "tradesClosed": [{"tradeID": "close-test-trade", "realizedPL": "1.00"}]
            });
            if let Some(price) = cfg.close_fill_price {
                fill["price"] = serde_json::json!(price);
            }
            Json(serde_json::json!({ "orderFillTransaction": fill }))
        }
        async fn trade(State(cfg): State<MockOanda>) -> Json<serde_json::Value> {
            Json(serde_json::json!({ "trade": cfg.trade }))
        }

        let app = Router::new()
            .route("/v3/accounts/{account_id}/orders", post(order))
            .route(
                "/v3/accounts/{account_id}/trades/{trade_id}/close",
                put(close),
            )
            .route("/v3/accounts/{account_id}/trades/{trade_id}", get(trade))
            .with_state(cfg);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        (format!("http://{}", addr), server)
    }

    async fn mock_oanda() -> (String, tokio::task::JoinHandle<()>) {
        mock_oanda_with(MockOanda::healthy()).await
    }

    /// An open long on `close-test-trade` for `strategy_id`, in the DB and in
    /// memory, as the evaluator would hold it.
    async fn seed_open_long(state: &AppState, strategy_id: Uuid) {
        live_trades_repo::insert_open_trade(
            &state.db,
            &NewLiveTrade {
                live_strategy_id: strategy_id,
                oanda_trade_id: "close-test-trade",
                instrument: INSTRUMENT,
                direction: Direction::Long,
                units: "1000",
                entry_price: 1.0,
                stop_loss_price: 0.8,
                entry_reason: "seeded",
                indicators_at_entry: &serde_json::json!({}),
                regime_at_entry: "unknown",
                sizing_metadata: &serde_json::json!({}),
                signal_price: 100.0,
                expected_entry_price: None,
                entry_spread: None,
            },
        )
        .await
        .unwrap();

        let mut position = make_position("close-test-trade", 1.0);
        position.strategy_id = strategy_id;
        position.instrument = INSTRUMENT.to_string();
        state
            .live
            .open_positions
            .write()
            .await
            .insert(position.trade_id.clone(), position);
    }

    async fn set_trading_enabled(state: &AppState, enabled: bool) {
        live_strategies_repo::upsert_trading_config(
            &state.db,
            "trading_enabled",
            &serde_json::json!(enabled.to_string()),
        )
        .await
        .unwrap();
    }

    async fn closed_exit_price(state: &AppState) -> (Option<String>, Option<f64>) {
        sqlx::query_as(
            "SELECT status, exit_price FROM live_trades WHERE oanda_trade_id = 'close-test-trade'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap()
    }

    /// Test-DB state wired to the mock OANDA, with the NAV, quote and
    /// instrument metadata sizing needs.
    async fn trading_state(oanda_url: &str) -> AppState {
        let mut state = AppState::for_tests_with_test_db().await;
        state.oanda = OandaClient::new(oanda_url, "http://127.0.0.1:1", "test-key", "test-account");

        *state.live.account.write().await = Some(AccountSnapshot {
            nav: 100_000.0,
            currency: "USD".to_string(),
            margin_available: 100_000.0,
            margin_used: 0.0,
            last_updated: Utc::now(),
        });
        state.live.last_quotes.write().await.insert(
            INSTRUMENT.to_string(),
            LastQuote {
                mid: 4.0,
                bid: 4.0,
                ask: 4.0,
                at: Utc::now(),
            },
        );
        state.live.instrument_metadata.write().await.insert(
            INSTRUMENT.to_string(),
            InstrumentMeta {
                min_trade_size: 1.0,
                max_trade_size: None,
                trade_units_precision: 0,
                policy_max_units: None,
                display_precision: 5,
            },
        );

        live_strategies_repo::upsert_trading_config(
            &state.db,
            "trading_enabled",
            &serde_json::json!("true"),
        )
        .await
        .unwrap();

        state
    }

    async fn seed_strategy(state: &AppState, parameters: serde_json::Value) -> Uuid {
        let id = Uuid::new_v4();
        live_strategies_repo::insert_live_strategy(
            &state.db,
            id,
            "mean_reversion",
            INSTRUMENT,
            "H1",
            &parameters,
        )
        .await
        .unwrap();
        sqlx::query("UPDATE live_strategies SET enabled = true WHERE id = $1")
            .bind(id)
            .execute(&state.db)
            .await
            .unwrap();
        id
    }

    async fn cleanup(state: &AppState, ids: &[Uuid]) {
        sqlx::query("DELETE FROM live_trades WHERE live_strategy_id = ANY($1)")
            .bind(ids)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("DELETE FROM live_strategies WHERE id = ANY($1)")
            .bind(ids)
            .execute(&state.db)
            .await
            .unwrap();
    }

    #[tokio::test]
    #[ignore = "requires AURO_TEST_DATABASE_URL (migrated test database)"]
    async fn evaluate_and_apply_serializes_same_key_without_torn_state() {
        let (oanda_url, server) = mock_oanda().await;
        let state = trading_state(&oanda_url).await;
        // 20% stop -> 1250 units at 1% risk = 5% of NAV each, inside every cap.
        let a = seed_strategy(&state, tf_parameters("serialize_a", -0.2)).await;
        let b = seed_strategy(&state, tf_parameters("serialize_b", -0.2)).await;

        let buffer = buffer_from_closes(&[3.0, 2.0, 1.0, 4.0]);
        let (state_a, state_b) = (state.clone(), state.clone());
        let (buffer_a, buffer_b) = (buffer.clone(), buffer.clone());
        let task_a = tokio::spawn(async move {
            evaluate_and_apply(
                &state_a,
                INSTRUMENT,
                Granularity::H1,
                &buffer_a,
                4.0,
                EvalScope::Full,
            )
            .await
            .unwrap()
        });
        let task_b = tokio::spawn(async move {
            evaluate_and_apply(
                &state_b,
                INSTRUMENT,
                Granularity::H1,
                &buffer_b,
                4.0,
                EvalScope::Full,
            )
            .await
            .unwrap()
        });
        let reports: Vec<SignalReport> = task_a
            .await
            .unwrap()
            .into_iter()
            .chain(task_b.await.unwrap())
            .collect();

        let opened = reports
            .iter()
            .filter(|r| matches!(r.action, SignalAction::OpenedLong))
            .count();
        assert_eq!(opened, 2, "expected both strategies to open exactly once");
        assert_eq!(state.live.open_positions.read().await.len(), 2);
        assert!(state
            .live
            .open_positions
            .read()
            .await
            .values()
            .all(|p| p.units == "1250"));

        let open_rows: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM live_trades WHERE live_strategy_id = ANY($1) AND status = 'open'",
        )
        .bind(&[a, b][..])
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(open_rows, 2, "expected two open live_trades rows");

        cleanup(&state, &[a, b]).await;
        server.abort();
    }

    #[tokio::test]
    #[ignore = "requires AURO_TEST_DATABASE_URL (migrated test database)"]
    async fn exits_only_scope_never_opens_a_position() {
        let (oanda_url, server) = mock_oanda().await;
        let state = trading_state(&oanda_url).await;
        let id = seed_strategy(&state, tf_parameters("exits_only", -0.2)).await;

        // The same bullish cross that opens a trade under EvalScope::Full.
        let buffer = buffer_from_closes(&[3.0, 2.0, 1.0, 4.0]);
        let reports = evaluate_and_apply(
            &state,
            INSTRUMENT,
            Granularity::H1,
            &buffer,
            4.0,
            EvalScope::ExitsOnly,
        )
        .await
        .unwrap();

        assert!(reports.is_empty(), "catch-up bars must not produce entries");
        assert!(state.live.open_positions.read().await.is_empty());

        cleanup(&state, &[id]).await;
        server.abort();
    }

    #[tokio::test]
    #[ignore = "requires AURO_TEST_DATABASE_URL (migrated test database)"]
    async fn evaluate_and_apply_closes_on_composite_exit_for_non_composite_label() {
        let (oanda_url, server) = mock_oanda().await;
        let state = trading_state(&oanda_url).await;
        let id = seed_strategy(&state, tf_parameters("composite_exit", -0.2)).await;
        seed_open_long(&state, id).await;

        let buffer = buffer_from_closes(&[1.0, 2.0, 3.0, 0.0]);
        let reports = evaluate_and_apply(
            &state,
            INSTRUMENT,
            Granularity::H1,
            &buffer,
            0.5,
            EvalScope::Full,
        )
        .await
        .unwrap();

        assert!(
            reports
                .iter()
                .any(|r| matches!(r.action, SignalAction::ClosedLong)),
            "expected composite exit to close long trade for non-composite strategy_type label"
        );
        assert!(state.live.open_positions.read().await.is_empty());

        let status: Option<String> = sqlx::query_scalar(
            "SELECT status FROM live_trades WHERE oanda_trade_id = 'close-test-trade'",
        )
        .fetch_optional(&state.db)
        .await
        .unwrap();
        assert_eq!(status.as_deref(), Some("closed"));

        cleanup(&state, &[id]).await;
        server.abort();
    }

    #[tokio::test]
    #[ignore = "requires AURO_TEST_DATABASE_URL (migrated test database)"]
    async fn kill_switch_blocks_entries_but_not_exits() {
        let (oanda_url, server) = mock_oanda().await;
        let state = trading_state(&oanda_url).await;
        set_trading_enabled(&state, false).await;
        let id = seed_strategy(&state, tf_parameters("kill_switch", -0.2)).await;

        // A bullish cross that opens a trade when trading is enabled.
        let entry_bars = buffer_from_closes(&[3.0, 2.0, 1.0, 4.0]);
        let reports = evaluate_and_apply(
            &state,
            INSTRUMENT,
            Granularity::H1,
            &entry_bars,
            4.0,
            EvalScope::Full,
        )
        .await
        .unwrap();
        assert!(reports.is_empty(), "kill switch must block entries");
        assert!(state.live.open_positions.read().await.is_empty());

        // The same switch must not stop an open position from taking its exit.
        seed_open_long(&state, id).await;
        let exit_bars = buffer_from_closes(&[1.0, 2.0, 3.0, 0.0]);
        let reports = evaluate_and_apply(
            &state,
            INSTRUMENT,
            Granularity::H1,
            &exit_bars,
            0.5,
            EvalScope::Full,
        )
        .await
        .unwrap();
        assert!(reports
            .iter()
            .any(|r| matches!(r.action, SignalAction::ClosedLong)));
        assert!(state.live.open_positions.read().await.is_empty());
        assert_eq!(
            closed_exit_price(&state).await,
            (Some("closed".into()), Some(0.5))
        );

        cleanup(&state, &[id]).await;
        server.abort();
    }

    #[tokio::test]
    #[ignore = "requires AURO_TEST_DATABASE_URL (migrated test database)"]
    async fn disabled_strategy_still_exits_its_open_position() {
        let (oanda_url, server) = mock_oanda().await;
        let state = trading_state(&oanda_url).await;
        let id = seed_strategy(&state, tf_parameters("disabled_exit", -0.2)).await;
        seed_open_long(&state, id).await;
        sqlx::query("UPDATE live_strategies SET enabled = false WHERE id = $1")
            .bind(id)
            .execute(&state.db)
            .await
            .unwrap();

        let exit_bars = buffer_from_closes(&[1.0, 2.0, 3.0, 0.0]);
        let reports = evaluate_and_apply(
            &state,
            INSTRUMENT,
            Granularity::H1,
            &exit_bars,
            0.5,
            EvalScope::Full,
        )
        .await
        .unwrap();
        assert!(reports
            .iter()
            .any(|r| matches!(r.action, SignalAction::ClosedLong)));
        assert!(state.live.open_positions.read().await.is_empty());

        cleanup(&state, &[id]).await;
        server.abort();
    }

    #[tokio::test]
    #[ignore = "requires AURO_TEST_DATABASE_URL (migrated test database)"]
    async fn entry_fill_price_is_looked_up_when_the_fill_omits_it() {
        let (oanda_url, server) = mock_oanda_with(MockOanda {
            order_fill_price: None,
            close_fill_price: Some("0.50000"),
            trade: serde_json::json!({"price": "4.12500"}),
        })
        .await;
        let state = trading_state(&oanda_url).await;
        let id = seed_strategy(&state, tf_parameters("fill_lookup", -0.2)).await;

        let entry_bars = buffer_from_closes(&[3.0, 2.0, 1.0, 4.0]);
        let reports = evaluate_and_apply(
            &state,
            INSTRUMENT,
            Granularity::H1,
            &entry_bars,
            4.0,
            EvalScope::Full,
        )
        .await
        .unwrap();
        assert!(reports
            .iter()
            .any(|r| matches!(r.action, SignalAction::OpenedLong)));
        {
            let positions = state.live.open_positions.read().await;
            assert_eq!(positions.len(), 1);
            assert_eq!(positions.values().next().unwrap().entry_price, 4.125);
        }

        let entry_price: Option<f64> =
            sqlx::query_scalar("SELECT entry_price FROM live_trades WHERE live_strategy_id = $1")
                .bind(id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(entry_price, Some(4.125));

        cleanup(&state, &[id]).await;
        server.abort();
    }

    #[tokio::test]
    #[ignore = "requires AURO_TEST_DATABASE_URL (migrated test database)"]
    async fn entry_with_no_knowable_fill_price_is_closed_not_tracked() {
        let (oanda_url, server) = mock_oanda_with(MockOanda {
            order_fill_price: None,
            close_fill_price: Some("0.50000"),
            trade: serde_json::json!({}),
        })
        .await;
        let state = trading_state(&oanda_url).await;
        let id = seed_strategy(&state, tf_parameters("fill_unknown", -0.2)).await;

        let entry_bars = buffer_from_closes(&[3.0, 2.0, 1.0, 4.0]);
        let reports = evaluate_and_apply(
            &state,
            INSTRUMENT,
            Granularity::H1,
            &entry_bars,
            4.0,
            EvalScope::Full,
        )
        .await
        .unwrap();
        assert!(reports.iter().any(|r| {
            matches!(r.action, SignalAction::EntryRejected)
                && r.reason == "fill_price_unknown:closed_untracked_trade"
        }));
        assert!(state.live.open_positions.read().await.is_empty());
        let rows: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM live_trades WHERE live_strategy_id = $1")
                .bind(id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(rows, 0, "an untracked trade must leave no row");

        cleanup(&state, &[id]).await;
        server.abort();
    }

    #[tokio::test]
    #[ignore = "requires AURO_TEST_DATABASE_URL (migrated test database)"]
    async fn exit_with_unknown_fill_price_is_recorded_as_unknown() {
        let (oanda_url, server) = mock_oanda_with(MockOanda {
            order_fill_price: Some("4.00000"),
            close_fill_price: None,
            trade: serde_json::json!({}),
        })
        .await;
        let state = trading_state(&oanda_url).await;
        let id = seed_strategy(&state, tf_parameters("exit_unknown", -0.2)).await;
        seed_open_long(&state, id).await;

        let exit_bars = buffer_from_closes(&[1.0, 2.0, 3.0, 0.0]);
        let reports = evaluate_and_apply(
            &state,
            INSTRUMENT,
            Granularity::H1,
            &exit_bars,
            0.5,
            EvalScope::Full,
        )
        .await
        .unwrap();
        assert!(reports
            .iter()
            .any(|r| matches!(r.action, SignalAction::ClosedLong)));
        assert!(state.live.open_positions.read().await.is_empty());
        assert_eq!(
            closed_exit_price(&state).await,
            (Some("closed".into()), None)
        );

        cleanup(&state, &[id]).await;
        server.abort();
    }

    fn make_position(trade_id: &str, entry_price: f64) -> OpenPosition {
        OpenPosition {
            strategy_id: Uuid::nil(),
            trade_id: trade_id.to_string(),
            instrument: "EUR_USD".to_string(),
            granularity: Granularity::H1,
            direction: Direction::Long,
            entry_price,
            entry_time: Utc::now() - Duration::hours(2),
            units: "1000".to_string(),
            stop_loss_state: StopLossState::NotApplicable,
            worst_price: entry_price,
            best_price: entry_price,
            strategy_type: "mean_reversion".to_string(),
        }
    }

    #[test]
    fn position_key_deltas_detects_added_and_removed_keys() {
        let mut before = HashMap::new();
        before.insert("t1".to_string(), make_position("t1", 1.1000));
        before.insert("t2".to_string(), make_position("t2", 1.2000));

        let mut after = HashMap::new();
        after.insert("t2".to_string(), make_position("t2", 1.2000));
        after.insert("t3".to_string(), make_position("t3", 1.3000));

        let (removed, added) = position_key_deltas(&before, &after);

        assert_eq!(removed, vec!["t1".to_string()]);
        assert_eq!(added.len(), 1);
        assert_eq!(added[0].0, "t3");
        assert_eq!(added[0].1.trade_id, "t3");
    }

    #[test]
    fn position_key_deltas_ignores_value_changes_for_existing_keys() {
        let mut before = HashMap::new();
        before.insert("t1".to_string(), make_position("t1", 1.1000));

        let mut after = HashMap::new();
        after.insert("t1".to_string(), make_position("t1", 1.1500));

        let (removed, added) = position_key_deltas(&before, &after);

        assert!(removed.is_empty());
        assert!(added.is_empty());
    }
}
