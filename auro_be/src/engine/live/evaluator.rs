use sqlx::PgPool;
use std::collections::HashMap;
use std::sync::Arc;

use crate::db::repositories::{live_queries, live_strategies as live_strategies_repo};
use crate::engine::indicators;
use crate::engine::mean_reversion::{self, MREntrySignal, MRExitSignal, MeanReversionParams};
use crate::engine::rules::{entry_gate_report, Rules};
use crate::engine::strategy::{self as strategy_mod, EntrySignal, ExitSignal, Strategy};
use crate::engine::types::{
    Direction, Granularity, LiveStrategy, OpenPosition, SignalAction, SignalReport, StopLossState,
};
use crate::oanda::client::OandaClient;
use crate::state::AppState;

use super::account_cache;
use super::format_price;
use super::risk_params;
use super::sizing::{check_concurrent_exposure, compute_units, SizingDecision, SizingInput};
use super::CandleBuffer;

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

pub(crate) async fn is_trading_enabled(pool: &PgPool) -> bool {
    live_queries::is_trading_enabled(pool)
        .await
        .unwrap_or(false)
}

pub(crate) async fn evaluate_and_apply(
    state: &AppState,
    instrument: &str,
    granularity: Granularity,
    buffer: &CandleBuffer,
    current_price: f64,
) -> Result<Vec<SignalReport>, Box<dyn std::error::Error + Send + Sync>> {
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
        &rules_snapshot,
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

#[allow(clippy::too_many_arguments)]
pub(crate) async fn evaluate_strategies(
    state: &AppState,
    instrument: &str,
    granularity: &Granularity,
    buffer: &CandleBuffer,
    current_price: f64,
    open_positions: &mut HashMap<String, OpenPosition>,
    rules: &Rules,
) -> Result<Vec<SignalReport>, Box<dyn std::error::Error + Send + Sync>> {
    if !is_trading_enabled(&state.db).await {
        return Ok(vec![]);
    }

    let strategies: Vec<LiveStrategy> =
        live_strategies_repo::list_enabled_for_instrument_granularity(
            &state.db,
            instrument,
            granularity.as_str(),
        )
        .await?;

    let mut reports: Vec<SignalReport> = Vec::new();

    for strategy in &strategies {
        let has_position = open_positions
            .values()
            .any(|p| p.strategy_id == strategy.id);

        if has_position {
            let exit_reports =
                evaluate_exit(state, strategy, current_price, buffer, open_positions).await?;
            reports.extend(exit_reports);
        } else if let Some(entry_report) = evaluate_entry(
            state,
            strategy,
            current_price,
            buffer,
            open_positions,
            rules,
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
    current_price: f64,
    buffer: &CandleBuffer,
    open_positions: &mut HashMap<String, OpenPosition>,
    rules: &Rules,
) -> Result<Option<SignalReport>, Box<dyn std::error::Error + Send + Sync>> {
    let params = &strategy.parameters;

    let already_open = open_positions.values().any(|pos| {
        pos.instrument == strategy.instrument
            && pos.granularity == strategy.granularity
            && pos.strategy_type == strategy.strategy_type
    });

    if already_open {
        tracing::debug!(
            "[SKIP ENTRY] {} {} - position already open on this instrument+granularity",
            strategy.instrument,
            strategy.granularity
        );
        return Ok(Some(SignalReport {
            strategy_id: strategy.id,
            strategy_type: strategy.strategy_type.clone(),
            instrument: strategy.instrument.clone(),
            granularity: strategy.granularity,
            action: SignalAction::EntryRejected,
            price: current_price,
            reason: "position_already_open".to_string(),
            oanda_trade_id: None,
        }));
    }

    if let Some(reason) = reject_incomplete_m5_tf_config(strategy) {
        tracing::warn!(
            "[SKIP ENTRY] {} {} {}: {}",
            strategy.strategy_type,
            strategy.instrument,
            strategy.granularity,
            reason
        );

        return Ok(Some(SignalReport {
            strategy_id: strategy.id,
            strategy_type: strategy.strategy_type.clone(),
            instrument: strategy.instrument.clone(),
            granularity: strategy.granularity,
            action: SignalAction::EntryRejected,
            price: current_price,
            reason,
            oanda_trade_id: None,
        }));
    }

    // Shape detection: composite-shape params have a "components" key. This lets
    // strategy_type stay logical ("trend_following", "mean_reversion") even after
    // a strategy class migrates to the composite shape — dispatch is driven by
    // the shape of the parameters JSON, not by strategy_type.
    let dispatch_key: &str = if params
        .as_object()
        .map(|o| o.contains_key("components"))
        .unwrap_or(false)
    {
        "composite"
    } else {
        strategy.strategy_type.as_str()
    };

    match dispatch_key {
        "mean_reversion" => {
            // MR v1: Z-score + RSI confirmed entry, bidirectional. Static OANDA
            // SL is set at the Z-extension price; TP is dynamic (return-to-mean)
            // and handled by Rust check_exit on each bar, so we pass None for TP.
            let mr_params = MeanReversionParams {
                ma_period: params["ma_period"].as_u64().unwrap_or(20) as usize,
                rsi_period: params["rsi_period"].as_u64().unwrap_or(14) as usize,
                entry_z_threshold: params["entry_z_threshold"].as_f64().unwrap_or(1.5),
                rsi_oversold: params["rsi_oversold"].as_f64().unwrap_or(30.0),
                rsi_overbought: params["rsi_overbought"].as_f64().unwrap_or(70.0),
                stop_z_threshold: params["stop_z_threshold"].as_f64().unwrap_or(3.5),
            };

            let candles_ref: &[crate::engine::types::Candle] = &buffer.candles;
            let warmup = mr_params.ma_period.max(mr_params.rsi_period + 1);

            // Diagnostic: compute Z + RSI for logging visibility
            if candles_ref.len() >= warmup {
                let z = indicators::z_score(candles_ref, mr_params.ma_period);
                let r = indicators::rsi(candles_ref, mr_params.rsi_period);
                tracing::info!(
                    "[STATUS] MR {} {} | price={:.5} Z={:?} RSI={:?} (entry |Z|>{:.2}, RSI<{} or >{}) | buf={}",
                    strategy.instrument,
                    strategy.granularity,
                    current_price,
                    z,
                    r,
                    mr_params.entry_z_threshold,
                    mr_params.rsi_oversold,
                    mr_params.rsi_overbought,
                    candles_ref.len(),
                );
            } else {
                tracing::info!(
                    "[STATUS] MR {} {} | buffer {}/{} — waiting for data",
                    strategy.instrument,
                    strategy.granularity,
                    candles_ref.len(),
                    warmup,
                );
            }

            let signal = mean_reversion::check_entry(candles_ref, &mr_params);
            let (direction, ma_value, z_at_entry, rsi_at_entry) = match signal {
                MREntrySignal::Long {
                    ma_value,
                    z_score,
                    rsi,
                } => (Direction::Long, ma_value, z_score, rsi),
                MREntrySignal::Short {
                    ma_value,
                    z_score,
                    rsi,
                } => (Direction::Short, ma_value, z_score, rsi),
                MREntrySignal::None => return Ok(None),
            };

            tracing::info!(
                "[SIGNAL] MR {:?} entry on {} ({}): price={:.5}, MA{}={:.5}, Z={:.3}, RSI={:.2}",
                direction,
                strategy.instrument,
                strategy.granularity,
                current_price,
                mr_params.ma_period,
                ma_value,
                z_at_entry,
                rsi_at_entry,
            );

            if let Some(gated) = entry_gate_report(rules, strategy, current_price) {
                return Ok(Some(gated));
            }

            // Compute SL price from Z-extension threshold.
            // Long:  SL = MA - stop_z_threshold * stdev (price further below MA)
            // Short: SL = MA + stop_z_threshold * stdev (price further above MA)
            // stdev is back-derived from (entry_price, ma_value, z_at_entry):
            //   z = (price - ma) / stdev  =>  stdev = (price - ma) / z
            // We use ma_value + entry-bar mid close + z_at_entry; for entry-bar
            // price use current_price (the mid). Z is non-zero by entry guard.
            let stdev = ((current_price - ma_value) / z_at_entry).abs();
            let sl_price = match direction {
                Direction::Long => ma_value - mr_params.stop_z_threshold * stdev,
                Direction::Short => ma_value + mr_params.stop_z_threshold * stdev,
            };

            let adx = indicators::adx(candles_ref, 14);
            let indicators_json = serde_json::json!({
                "strategy_version": "v1",
                "ma_period": mr_params.ma_period,
                "ma_value": ma_value,
                "z_score": z_at_entry,
                "rsi": rsi_at_entry,
                "stdev": stdev,
                "adx": adx,
            });
            let (_, regime_reason) = rules.decision(&strategy.id);
            let regime = regime_reason.unwrap_or("unknown").to_string();

            return execute_entry(
                state,
                strategy,
                &direction,
                &strategy.max_position_size,
                strategy.risk_pct,
                strategy.max_units,
                current_price,
                sl_price,
                None, // dynamic TP via check_exit
                &format!(
                    "MR v1 {:?}: MA{}={:.5}, Z={:.3}, RSI={:.2}",
                    direction, mr_params.ma_period, ma_value, z_at_entry, rsi_at_entry
                ),
                indicators_json,
                regime,
                open_positions,
            )
            .await;
        }
        "composite" => {
            // New canonical strategy shape. All parameters live inside the
            // Strategy struct (components, entry/exit selectors, stop, sizing).
            let composite: Strategy = match serde_json::from_value(params.clone()) {
                Ok(s) => s,
                Err(e) => {
                    tracing::warn!(
                        "[SKIP ENTRY] composite parse failure for {} {}: {}",
                        strategy.instrument,
                        strategy.granularity,
                        e
                    );
                    return Ok(None);
                }
            };

            let candles_ref: &[crate::engine::types::Candle] = &buffer.candles;
            let warmup = composite.warmup();
            if candles_ref.len() < warmup {
                tracing::info!(
                    "[STATUS] composite {} {} | buffer {}/{} — waiting for data",
                    strategy.instrument,
                    strategy.granularity,
                    candles_ref.len(),
                    warmup,
                );
                return Ok(None);
            }

            let ports = match composite.compute_ports(candles_ref) {
                Some(p) => p,
                None => return Ok(None),
            };

            tracing::info!(
                "[STATUS] composite {} {} | ports={:?} | buf={}",
                strategy.instrument,
                strategy.granularity,
                ports,
                candles_ref.len(),
            );

            let entry_signal = composite.evaluate_entry(&ports);
            let direction = match entry_signal {
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

            let sl_price = match strategy_mod::compute_stop_price(
                &composite,
                current_price,
                direction,
                candles_ref,
            ) {
                Some(p) => p,
                None => {
                    tracing::warn!(
                        "[SKIP ENTRY] composite {} {} — stop config could not compute SL (component-derived stop returned None)",
                        strategy.instrument,
                        strategy.granularity,
                    );
                    return Ok(None);
                }
            };
            let units_to_use = match direction {
                Direction::Long => strategy.max_position_size.clone(),
                Direction::Short => format!("-{}", strategy.max_position_size),
            };

            let adx = indicators::adx(candles_ref, 14);
            let indicators_json = serde_json::json!({
                "strategy_version": composite.version,
                "components": composite.components.keys().collect::<Vec<_>>(),
                "ports": ports,
                "adx": adx,
            });
            let (_, regime_reason) = rules.decision(&strategy.id);
            let regime = regime_reason.unwrap_or("unknown").to_string();

            return execute_entry(
                state,
                strategy,
                &direction,
                &units_to_use,
                strategy.risk_pct,
                strategy.max_units,
                current_price,
                sl_price,
                None, // no static TP — exit handled by composite strategy's exit selector
                &format!("Composite {:?} entry", direction),
                indicators_json,
                regime,
                open_positions,
            )
            .await;
        }
        _ => {}
    }
    Ok(None)
}

fn reject_incomplete_m5_tf_config(_strategy: &LiveStrategy) -> Option<String> {
    // Deprecated: old-shape TF strategies (which required confirm_bars/trailing_k)
    // are no longer supported. Composite-shape TF v1 doesn't use these
    // parameters. Kept as a no-op for call-site symmetry until callers are
    // refactored.
    None
}

#[allow(clippy::too_many_arguments)]
async fn execute_entry(
    state: &AppState,
    strategy: &LiveStrategy,
    direction: &Direction,
    static_units: &str,
    risk_pct: f64,
    strategy_max_units: Option<i64>,
    current_price: f64,
    sl_price: f64,
    tp_price: Option<f64>,
    entry_reason: &str,
    indicators_at_entry: serde_json::Value,
    regime_at_entry: String,
    open_positions: &mut HashMap<String, OpenPosition>,
) -> Result<Option<SignalReport>, Box<dyn std::error::Error + Send + Sync>> {
    let mut units_to_use = static_units.to_string();
    let mut sizing_metadata_json: Option<serde_json::Value> = None;

    let instrument_meta = {
        let cache = state.live.instrument_metadata.read().await;
        cache.get(&strategy.instrument).cloned()
    }
    .ok_or_else(|| {
        std::io::Error::other(format!(
            "[SIZING] missing instrument metadata for {}",
            strategy.instrument
        ))
    })?;

    if risk_pct == 0.0 {
        let parsed: i64 = static_units.parse().unwrap_or(1000);
        let parsed_abs = parsed.abs();
        let policy_cap = instrument_meta.policy_max_units;
        let oanda_min = instrument_meta.min_trade_size;

        let effective_abs = match policy_cap {
            Some(cap) => parsed_abs.min(cap),
            None => parsed_abs,
        };

        if effective_abs < oanda_min {
            tracing::warn!(
                "[SIZING] {} {} skip reason=policy_below_minimum policy_cap={:?} oanda_min={} requested={}",
                strategy.id,
                strategy.instrument,
                policy_cap,
                oanda_min,
                parsed
            );
            return Ok(Some(SignalReport {
                strategy_id: strategy.id,
                strategy_type: strategy.strategy_type.clone(),
                instrument: strategy.instrument.clone(),
                granularity: strategy.granularity,
                action: SignalAction::EntryRejected,
                price: current_price,
                reason: "sizing_skip:policy_below_minimum".to_string(),
                oanda_trade_id: None,
            }));
        }

        let effective = if parsed < 0 {
            -effective_abs
        } else {
            effective_abs
        };

        if effective_abs < parsed_abs {
            tracing::info!(
                "[SIZING] {} {} policy_clamp parsed={} -> effective={} policy_cap={:?}",
                strategy.id,
                strategy.instrument,
                parsed,
                effective,
                policy_cap
            );
        } else {
            tracing::info!(
                "[SIZING] {} {} static fallback units={}",
                strategy.id,
                strategy.instrument,
                static_units
            );
        }

        units_to_use = effective.to_string();
    } else {
        let account_snapshot = { state.live.account.read().await.clone() };

        if let Some(snapshot) = account_snapshot {
            let decision = compute_units(SizingInput {
                equity: snapshot.nav,
                risk_pct,
                entry_price: current_price,
                sl_price,
                instrument: &strategy.instrument,
                instrument_min_units: instrument_meta.min_trade_size,
                instrument_max_units: instrument_meta.max_trade_size,
                instrument_policy_max_units: instrument_meta.policy_max_units,
                strategy_max_units,
            });

            match decision {
                SizingDecision::Skip { reason, metadata } => {
                    tracing::warn!(
                        "[SIZING] {} {} skip reason={} equity={} risk_pct={} raw_units={}",
                        strategy.id,
                        strategy.instrument,
                        reason.as_str(),
                        snapshot.nav,
                        risk_pct,
                        metadata.raw_units
                    );
                    return Ok(Some(SignalReport {
                        strategy_id: strategy.id,
                        strategy_type: strategy.strategy_type.clone(),
                        instrument: strategy.instrument.clone(),
                        granularity: strategy.granularity,
                        action: SignalAction::EntryRejected,
                        price: current_price,
                        reason: format!("sizing_skip:{}", reason.as_str()),
                        oanda_trade_id: None,
                    }));
                }
                SizingDecision::Place { units, metadata } => {
                    let new_notional = (units as f64).abs() * current_price.abs();
                    if let Err(reason) =
                        check_concurrent_exposure(state, new_notional, snapshot.nav).await
                    {
                        tracing::warn!(
                            "[SIZING] {} {} skip reason={} equity={} risk_pct={} raw_units={}",
                            strategy.id,
                            strategy.instrument,
                            reason.as_str(),
                            snapshot.nav,
                            risk_pct,
                            metadata.raw_units
                        );
                        return Ok(Some(SignalReport {
                            strategy_id: strategy.id,
                            strategy_type: strategy.strategy_type.clone(),
                            instrument: strategy.instrument.clone(),
                            granularity: strategy.granularity,
                            action: SignalAction::EntryRejected,
                            price: current_price,
                            reason: format!("sizing_skip:{}", reason.as_str()),
                            oanda_trade_id: None,
                        }));
                    }

                    tracing::info!(
                        "[SIZING] {} {} place units={} equity={} risk_pct={} sl_dist={} notional_pct={} clamps={:?}",
                        strategy.id,
                        strategy.instrument,
                        units,
                        snapshot.nav,
                        risk_pct,
                        metadata.sl_distance,
                        metadata.notional_pct_of_nav,
                        metadata.clamps_applied
                    );

                    let signed_units = match direction {
                        Direction::Long => units,
                        Direction::Short => -units,
                    };
                    units_to_use = signed_units.to_string();
                    sizing_metadata_json = Some(serde_json::to_value(&metadata)?);
                }
            }
        } else {
            tracing::warn!(
                "[SIZING] {} {} account snapshot unavailable; static fallback units={}",
                strategy.id,
                strategy.instrument,
                static_units
            );
        }
    }

    let tp_str = match tp_price {
        Some(p) => Some(format_price(state, &strategy.instrument, p).await),
        None => None,
    };

    let trailing_k_override = strategy
        .parameters
        .get("trailing_k")
        .and_then(|v| v.as_f64());

    // nil-TP trend-following: open with a trailing stop instead of a fixed SL.
    // Trailing distance is ATR-adaptive: K * ATR.
    let trailing_dist_str;
    let sl_str;
    let (use_sl, use_trailing) = if tp_price.is_none()
        && strategy.strategy_type == "trend_following"
    {
        let distance =
                risk_params::trailing_distance_price(
                    state,
                    &strategy.instrument,
                    &strategy.strategy_type,
                    strategy.granularity,
                    current_price,
                    trailing_k_override,
                )
                .await
                .unwrap_or_else(|| {
                    tracing::warn!(
                        "[RISK PARAMS] Falling back to SL-derived trailing distance on nil-TP entry for {} {}",
                        strategy.instrument,
                        strategy.id
                    );
                    (current_price - sl_price).abs()
                });
        trailing_dist_str = format_price(state, &strategy.instrument, distance).await;
        sl_str = String::new();
        (false, true)
    } else {
        sl_str = format_price(state, &strategy.instrument, sl_price).await;
        trailing_dist_str = String::new();
        (true, false)
    };

    let initial_sl_state = if use_trailing {
        StopLossState::Trailing
    } else {
        StopLossState::initial_for_strategy_type(&strategy.strategy_type)
    };

    match state
        .oanda
        .create_market_order(
            &strategy.instrument,
            &units_to_use,
            if use_sl { Some(&sl_str) } else { None },
            tp_str.as_deref(),
            if use_trailing {
                Some(&trailing_dist_str)
            } else {
                None
            },
        )
        .await
    {
        Ok(resp) => {
            let trade_id = resp["orderFillTransaction"]["tradeOpened"]["tradeID"]
                .as_str()
                .unwrap_or("unknown")
                .to_string();

            if trade_id == "unknown" {
                tracing::error!(
                    "[ORDER FAILED] {} {} ({}) missing tradeID in OANDA response; skipping in-memory/DB insert",
                    direction,
                    strategy.instrument,
                    strategy.granularity,
                );
                return Ok(None);
            }

            let fill_price = resp["orderFillTransaction"]["price"]
                .as_str()
                .and_then(|p| p.parse::<f64>().ok())
                .unwrap_or(current_price);

            tracing::info!(
                "[TRADE] Opened {} {} ({}) @ {:.5}, SL={}, TP={}, trade_id={}",
                direction,
                strategy.instrument,
                strategy.granularity,
                fill_price,
                sl_str,
                tp_str.as_deref().unwrap_or("none"),
                trade_id
            );

            sqlx::query(
                r#"INSERT INTO live_trades
                    (live_strategy_id, oanda_trade_id, instrument, direction, units,
                     entry_price, stop_loss_price, take_profit_price, entry_reason,
                                         indicators_at_entry, regime_at_entry, sizing_metadata, status)
                                     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, 'open')"#,
            )
            .bind(strategy.id)
            .bind(&trade_id)
            .bind(&strategy.instrument)
            .bind(direction)
                        .bind(&units_to_use)
            .bind(fill_price)
            .bind(sl_price)
            .bind(tp_price)
            .bind(entry_reason)
            .bind(&indicators_at_entry)
            .bind(&regime_at_entry)
                        .bind(&sizing_metadata_json)
                        .execute(&state.db)
            .await?;

            let state_for_refresh = state.clone();
            tokio::spawn(async move {
                account_cache::refresh_once(&state_for_refresh).await;
            });

            let action = match direction {
                Direction::Long => SignalAction::OpenedLong,
                Direction::Short => SignalAction::OpenedShort,
            };

            let report = SignalReport {
                strategy_id: strategy.id,
                strategy_type: strategy.strategy_type.clone(),
                instrument: strategy.instrument.clone(),
                granularity: strategy.granularity,
                action,
                price: current_price,
                reason: entry_reason.to_string(),
                oanda_trade_id: Some(trade_id.clone()),
            };

            open_positions.insert(
                trade_id.to_string(),
                OpenPosition {
                    strategy_id: strategy.id,
                    trade_id,
                    instrument: strategy.instrument.clone(),
                    granularity: strategy.granularity,
                    direction: *direction,
                    entry_price: fill_price,
                    units: units_to_use.clone(),
                    stop_loss_state: initial_sl_state,
                    worst_price: fill_price,
                    best_price: fill_price,
                    transition_failed_at: None,
                    strategy_type: strategy.strategy_type.clone(),
                },
            );

            Ok(Some(report))
        }
        Err(e) => {
            tracing::error!(
                "[ORDER FAILED] {} {} ({}): {}",
                direction,
                strategy.instrument,
                strategy.granularity,
                e
            );
            Ok(None)
        }
    }
}

async fn evaluate_exit(
    state: &AppState,
    strategy: &LiveStrategy,
    current_price: f64,
    buffer: &CandleBuffer,
    open_positions: &mut HashMap<String, OpenPosition>,
) -> Result<Vec<SignalReport>, Box<dyn std::error::Error + Send + Sync>> {
    let positions_for_strategy: Vec<OpenPosition> = open_positions
        .values()
        .filter(|p| p.strategy_id == strategy.id)
        .cloned()
        .collect();

    if positions_for_strategy.is_empty() {
        return Ok(vec![]);
    }

    let params = &strategy.parameters;
    let mut should_exit = false;
    let mut exit_reason = String::new();

    // Same shape detection as the entry path.
    let dispatch_key: &str = if params
        .as_object()
        .map(|o| o.contains_key("components"))
        .unwrap_or(false)
    {
        "composite"
    } else {
        strategy.strategy_type.as_str()
    };

    match dispatch_key {
        "mean_reversion" => {
            // MR v1 dynamic exit: on each bar, check whether Z has crossed
            // back through zero (return-to-mean) or extended past the stop
            // threshold (Z-stop). OANDA holds the static SL server-side as
            // catastrophic protection; this path triggers the primary exit.
            let mr_params = MeanReversionParams {
                ma_period: params["ma_period"].as_u64().unwrap_or(20) as usize,
                rsi_period: params["rsi_period"].as_u64().unwrap_or(14) as usize,
                entry_z_threshold: params["entry_z_threshold"].as_f64().unwrap_or(1.5),
                rsi_oversold: params["rsi_oversold"].as_f64().unwrap_or(30.0),
                rsi_overbought: params["rsi_overbought"].as_f64().unwrap_or(70.0),
                stop_z_threshold: params["stop_z_threshold"].as_f64().unwrap_or(3.5),
            };
            let candles_ref: &[crate::engine::types::Candle] = &buffer.candles;
            let direction = positions_for_strategy[0].direction;
            match mean_reversion::check_exit(candles_ref, &mr_params, direction) {
                MRExitSignal::ReturnToMean { ma_value, z_score } => {
                    should_exit = true;
                    exit_reason = format!("ReturnToMean: MA={:.5}, Z={:.3}", ma_value, z_score);
                }
                MRExitSignal::ZStop { z_score } => {
                    should_exit = true;
                    exit_reason = format!("ZStop: Z={:.3}", z_score);
                }
                MRExitSignal::Hold => {}
            }
        }
        "composite" => {
            // New canonical strategy shape: evaluate the exit selector against
            // computed component ports. On Exit, close via OANDA.
            let composite: Strategy = match serde_json::from_value(params.clone()) {
                Ok(s) => s,
                Err(e) => {
                    tracing::warn!(
                        "[EXIT CHECK] composite parse failure for {} {}: {}",
                        strategy.instrument,
                        strategy.granularity,
                        e
                    );
                    return Ok(vec![]);
                }
            };
            let candles_ref: &[crate::engine::types::Candle] = &buffer.candles;
            let ports = match composite.compute_ports(candles_ref) {
                Some(p) => p,
                None => return Ok(vec![]),
            };
            let is_long = positions_for_strategy[0].direction == Direction::Long;
            if matches!(composite.evaluate_exit(&ports, is_long), ExitSignal::Exit) {
                should_exit = true;
                exit_reason = format!("CompositeExit (ports={:?})", ports);
            }
        }
        _ => {}
    }

    let mut reports = Vec::<SignalReport>::new();

    if should_exit {
        for pos in &positions_for_strategy {
            let trade_id = pos.trade_id.clone();
            let direction = pos.direction;
            let entry_price = pos.entry_price;
            let instrument = pos.instrument.clone();

            tracing::info!(
                "[EXIT SIGNAL] {} on {} ({}): {}",
                direction,
                instrument,
                strategy.granularity,
                exit_reason
            );

            match state.oanda.close_trade(&trade_id, None).await {
                Ok(resp) => {
                    let fill_price = resp["orderFillTransaction"]["price"]
                        .as_str()
                        .and_then(|p| p.parse::<f64>().ok())
                        .unwrap_or(current_price);
                    let realized_pl = extract_realized_pl(&state.oanda, &resp, &trade_id).await;

                    let pnl = match direction {
                        Direction::Long => (fill_price - entry_price) / entry_price,
                        Direction::Short => (entry_price - fill_price) / entry_price,
                    };

                    tracing::info!(
                        "[TRADE CLOSED] {} {} ({}) @ {:.5}, PnL={:.4}%, reason={}",
                        direction,
                        instrument,
                        strategy.granularity,
                        fill_price,
                        pnl * 100.0,
                        exit_reason
                    );

                    sqlx::query(
                        r#"UPDATE live_trades
                        SET exit_price = $1, exit_time = NOW(), pnl_percent = $2,
                            pnl = $3, exit_reason = $4, status = 'closed',
                            stop_loss_state_at_close = $5, updated_at = NOW()
                        WHERE oanda_trade_id = $6"#,
                    )
                    .bind(fill_price)
                    .bind(pnl)
                    .bind(realized_pl)
                    .bind(&exit_reason)
                    .bind(pos.stop_loss_state.as_str())
                    .bind(&trade_id)
                    .execute(&state.db)
                    .await?;

                    let state_for_refresh = state.clone();
                    tokio::spawn(async move {
                        account_cache::refresh_once(&state_for_refresh).await;
                    });

                    open_positions.remove(&trade_id);

                    let action = match direction {
                        Direction::Long => SignalAction::ClosedLong,
                        Direction::Short => SignalAction::ClosedShort,
                    };

                    reports.push(SignalReport {
                        strategy_id: strategy.id,
                        strategy_type: strategy.strategy_type.clone(),
                        instrument: instrument.clone(),
                        granularity: strategy.granularity,
                        action,
                        price: fill_price,
                        reason: exit_reason.clone(),
                        oanda_trade_id: Some(trade_id.clone()),
                    });
                }
                Err(e) => {
                    tracing::error!("[CLOSE FAILED] {} {}: {}", direction, instrument, e);
                }
            }
        }
    }

    Ok(reports)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::num::NonZeroUsize;
    use std::sync::{Arc, Mutex};

    use axum::routing::post;
    use axum::{Json, Router};
    use chrono::{Duration, Utc};
    use lru::LruCache;
    use tokio::sync::broadcast;
    use uuid::Uuid;

    use crate::config::Config;
    use crate::engine::types::{Candle, OHLC};
    use crate::oanda::client::OandaClient;
    use crate::state::{AppState, LiveState};

    fn make_position(trade_id: &str, entry_price: f64) -> OpenPosition {
        OpenPosition {
            strategy_id: Uuid::nil(),
            trade_id: trade_id.to_string(),
            instrument: "EUR_USD".to_string(),
            granularity: Granularity::H1,
            direction: Direction::Long,
            entry_price,
            units: "1000".to_string(),
            stop_loss_state: StopLossState::Initial,
            worst_price: entry_price,
            best_price: entry_price,
            transition_failed_at: None,
            strategy_type: "mean_reversion".to_string(),
        }
    }

    async fn mock_order_handler() -> Json<serde_json::Value> {
        Json(serde_json::json!({
            "orderFillTransaction": {
                "tradeOpened": { "tradeID": "lock-test-trade-1" },
                "price": "4.00000"
            }
        }))
    }

    #[tokio::test]
    async fn evaluate_and_apply_serializes_same_key_to_single_open_position() {
        let db_url = match std::env::var("AURO_TEST_DATABASE_URL") {
            Ok(url) => url,
            Err(_) => return,
        };

        let db = match sqlx::PgPool::connect(&db_url).await {
            Ok(pool) => pool,
            Err(_) => return,
        };

        sqlx::query(
            r#"CREATE TABLE IF NOT EXISTS trading_config (
                key VARCHAR(50) PRIMARY KEY,
                value JSONB NOT NULL,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )"#,
        )
        .execute(&db)
        .await
        .unwrap();

        sqlx::query(
            r#"CREATE TABLE IF NOT EXISTS live_strategies (
                id UUID PRIMARY KEY,
                strategy_type VARCHAR(50) NOT NULL,
                instrument VARCHAR(20) NOT NULL,
                granularity VARCHAR(5) NOT NULL,
                parameters JSONB NOT NULL,
                enabled BOOLEAN NOT NULL DEFAULT false,
                max_position_size VARCHAR(20) NOT NULL DEFAULT '1000',
                risk_pct DOUBLE PRECISION NOT NULL DEFAULT 0.0,
                max_units BIGINT NULL
            )"#,
        )
        .execute(&db)
        .await
        .unwrap();

        sqlx::query(
            r#"CREATE TABLE IF NOT EXISTS live_trades (
                id BIGSERIAL PRIMARY KEY,
                live_strategy_id UUID,
                oanda_trade_id VARCHAR(50),
                instrument VARCHAR(20) NOT NULL,
                direction VARCHAR(10) NOT NULL,
                units VARCHAR(20) NOT NULL,
                entry_price DOUBLE PRECISION,
                exit_price DOUBLE PRECISION,
                entry_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                exit_time TIMESTAMPTZ,
                stop_loss_price DOUBLE PRECISION,
                take_profit_price DOUBLE PRECISION,
                pnl DOUBLE PRECISION,
                pnl_percent DOUBLE PRECISION,
                entry_reason TEXT,
                exit_reason TEXT,
                status VARCHAR(20) NOT NULL DEFAULT 'open',
                indicators_at_entry JSONB,
                regime_at_entry VARCHAR(120),
                sizing_metadata JSONB,
                stop_loss_state_at_close VARCHAR(20),
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )"#,
        )
        .execute(&db)
        .await
        .unwrap();

        sqlx::query(
            "INSERT INTO trading_config (key, value) VALUES ('trading_enabled', $1::jsonb)
               ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
        )
        .bind("\"true\"")
        .execute(&db)
        .await
        .unwrap();

        let strategy_a = Uuid::new_v4();
        let strategy_b = Uuid::new_v4();
        let instrument = "LT_EVAL_H1".to_string();

        sqlx::query("DELETE FROM live_trades WHERE live_strategy_id = $1 OR live_strategy_id = $2")
            .bind(strategy_a)
            .bind(strategy_b)
            .execute(&db)
            .await
            .unwrap();

        sqlx::query("DELETE FROM live_strategies WHERE id = $1 OR id = $2")
            .bind(strategy_a)
            .bind(strategy_b)
            .execute(&db)
            .await
            .unwrap();

        sqlx::query(
              "INSERT INTO live_strategies (id, strategy_type, instrument, granularity, parameters, enabled, max_position_size, risk_pct, max_units)
               VALUES ($1, 'trend_following', $2, 'H1', $3, true, '1000', 0.0, NULL)",
        )
        .bind(strategy_a)
        .bind(&instrument)
        .bind(serde_json::json!({
            "fast_period": 2,
            "slow_period": 3,
            "stop_loss": -0.02,
            "take_profit": 0.05
        }))
        .execute(&db)
        .await
        .unwrap();

        sqlx::query(
              "INSERT INTO live_strategies (id, strategy_type, instrument, granularity, parameters, enabled, max_position_size, risk_pct, max_units)
               VALUES ($1, 'trend_following', $2, 'H1', $3, true, '1000', 0.0, NULL)",
        )
        .bind(strategy_b)
        .bind(&instrument)
        .bind(serde_json::json!({
            "fast_period": 2,
            "slow_period": 3,
            "stop_loss": -0.02,
            "take_profit": 0.05,
            "variant": "b"
        }))
        .execute(&db)
        .await
        .unwrap();

        let app = Router::new().route("/v3/accounts/:account_id/orders", post(mock_order_handler));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });

        let config = Config {
            database_url: db_url,
            oanda_api_key: "test-key".to_string(),
            oanda_account_id: "test-account".to_string(),
            oanda_base_url: format!("http://{}", addr),
            oanda_stream_url: "http://127.0.0.1:1".to_string(),
            host: "127.0.0.1".to_string(),
            port: 0,
        };

        let oanda = OandaClient::new(
            &config.oanda_base_url,
            &config.oanda_stream_url,
            &config.oanda_api_key,
            &config.oanda_account_id,
        );

        let (price_tx, _) = broadcast::channel(8);
        let state = AppState {
            db: db.clone(),
            config,
            oanda,
            start_time: Utc::now(),
            live: Arc::new(LiveState::new()),
            price_tx,
            eval_cache: Arc::new(Mutex::new(LruCache::new(NonZeroUsize::new(16).unwrap()))),
        };

        let mut buffer = CandleBuffer::new(16);
        let base = Utc::now();
        for (idx, close) in [3.0, 2.0, 1.0, 4.0].iter().enumerate() {
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

        let state_a = state.clone();
        let state_b = state.clone();
        let buffer_a = buffer.clone();
        let buffer_b = buffer.clone();
        let instrument_a = instrument.clone();
        let instrument_b = instrument.clone();

        let task_a = tokio::spawn(async move {
            evaluate_and_apply(&state_a, &instrument_a, Granularity::H1, &buffer_a, 4.0)
                .await
                .unwrap()
        });

        let task_b = tokio::spawn(async move {
            evaluate_and_apply(&state_b, &instrument_b, Granularity::H1, &buffer_b, 4.0)
                .await
                .unwrap()
        });

        let reports_a = task_a.await.unwrap();
        let reports_b = task_b.await.unwrap();

        let mut opened = 0usize;
        let mut rejected = 0usize;
        for report in reports_a.iter().chain(reports_b.iter()) {
            if matches!(
                report.action,
                SignalAction::OpenedLong | SignalAction::OpenedShort
            ) {
                opened += 1;
            }
            if matches!(report.action, SignalAction::EntryRejected)
                && report.reason == "position_already_open"
            {
                rejected += 1;
            }
        }

        assert_eq!(opened, 1, "expected exactly one opened position");
        assert!(
            rejected >= 1,
            "expected at least one position_already_open rejection"
        );

        let positions = state.live.open_positions.read().await;
        assert_eq!(positions.len(), 1, "expected exactly one open position");
        let strategy_id = positions.values().next().unwrap().strategy_id;
        assert!(strategy_id == strategy_a || strategy_id == strategy_b);
        drop(positions);

        sqlx::query("DELETE FROM live_trades WHERE live_strategy_id = $1 OR live_strategy_id = $2")
            .bind(strategy_a)
            .bind(strategy_b)
            .execute(&db)
            .await
            .unwrap();
        sqlx::query("DELETE FROM live_strategies WHERE id = $1 OR id = $2")
            .bind(strategy_a)
            .bind(strategy_b)
            .execute(&db)
            .await
            .unwrap();

        server.abort();
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
