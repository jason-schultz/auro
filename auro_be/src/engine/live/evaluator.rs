use sqlx::PgPool;
use std::collections::HashMap;

use crate::engine::mean_reversion::{self, MRSignal, MeanReversionParams};
use crate::engine::rules::{entry_gate_report, Rules};
use crate::engine::trend_following::{self, TFSignal, TrendFollowingParams};
use crate::engine::types::{
    Direction, Granularity, LiveStrategy, OpenPosition, SignalAction, SignalReport, StopLossState,
};
use crate::oanda::client::OandaClient;

use super::format_price;
use super::CandleBuffer;

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
    let result: Option<(serde_json::Value,)> =
        sqlx::query_as("SELECT value FROM trading_config WHERE key = 'trading_enabled'")
            .fetch_optional(pool)
            .await
            .unwrap_or(None);

    result
        .and_then(|r| r.0.as_str().map(|s| s == "true"))
        .unwrap_or(false)
}

pub(crate) async fn evaluate_strategies(
    pool: &PgPool,
    oanda: &OandaClient,
    instrument: &str,
    granularity: &Granularity,
    buffer: &CandleBuffer,
    current_price: f64,
    open_positions: &mut HashMap<String, OpenPosition>,
    rules: &Rules,
) -> Result<Vec<SignalReport>, Box<dyn std::error::Error + Send + Sync>> {
    if !is_trading_enabled(pool).await {
        return Ok(vec![]);
    }

    let strategies: Vec<LiveStrategy> = sqlx::query_as(
        "SELECT id, strategy_type, instrument, granularity, parameters, enabled, max_position_size \
         FROM live_strategies WHERE instrument = $1 AND granularity = $2 AND enabled = true"
    )
    .bind(instrument)
    .bind(granularity.as_str())
    .fetch_all(pool)
    .await?;

    let mut reports: Vec<SignalReport> = Vec::new();

    for strategy in &strategies {
        let has_position = open_positions
            .values()
            .any(|p| p.strategy_id == strategy.id);

        if has_position {
            let exit_reports =
                evaluate_exit(pool, oanda, strategy, current_price, buffer, open_positions).await?;
            reports.extend(exit_reports);
        } else if let Some(entry_report) = evaluate_entry(
            pool,
            oanda,
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

    Ok(reports)
}

async fn evaluate_entry(
    pool: &PgPool,
    oanda: &OandaClient,
    strategy: &LiveStrategy,
    current_price: f64,
    buffer: &CandleBuffer,
    open_positions: &mut HashMap<String, OpenPosition>,
    rules: &Rules,
) -> Result<Option<SignalReport>, Box<dyn std::error::Error + Send + Sync>> {
    let params = &strategy.parameters;

    let already_open = open_positions
        .values()
        .any(|pos| pos.instrument == strategy.instrument);

    if already_open {
        tracing::debug!(
            "[SKIP ENTRY] {} {} - position already open on this instrument",
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

    match strategy.strategy_type.as_str() {
        "mean_reversion" => {
            let mr_params = MeanReversionParams {
                ma_period: params["ma_period"].as_u64().unwrap_or(20) as usize,
                entry_threshold: params["entry_threshold"].as_f64().unwrap_or(-0.01),
                exit_threshold: params["exit_threshold"].as_f64().unwrap_or(0.003),
                stop_loss: params["stop_loss"].as_f64().unwrap_or(-0.005),
                regime_filter: false, // live path: regime gating handled by Elixir rules engine
            };

            let closes = buffer.closes();

            // Diagnostic: compute MA and deviation for logging
            if closes.len() >= mr_params.ma_period {
                let ma: f64 = closes[closes.len() - mr_params.ma_period..]
                    .iter()
                    .sum::<f64>()
                    / mr_params.ma_period as f64;
                let deviation = (current_price - ma) / ma;
                tracing::info!(
                    "[STATUS] MR {} {} | price={:.5} MA{}={:.5} dev={:.4}% (need {:.4}%) | buf={}",
                    strategy.instrument,
                    strategy.granularity,
                    current_price,
                    mr_params.ma_period,
                    ma,
                    deviation * 100.0,
                    mr_params.entry_threshold * 100.0,
                    closes.len(),
                );
            } else {
                tracing::info!(
                    "[STATUS] MR {} {} | buffer {}/{} — waiting for data",
                    strategy.instrument,
                    strategy.granularity,
                    closes.len(),
                    mr_params.ma_period,
                );
            }

            match mean_reversion::check_entry(&closes, &mr_params) {
                MRSignal::Enter {
                    ma_value,
                    deviation_pct,
                } => {
                    tracing::info!(
                        "[SIGNAL] Mean reversion entry on {} ({}): price={:.5}, MA{}={:.5}, deviation={:.4}%",
                        strategy.instrument, strategy.granularity, current_price, mr_params.ma_period, ma_value, deviation_pct * 100.0
                    );

                    if let Some(gated) = entry_gate_report(rules, strategy, current_price) {
                        return Ok(Some(gated));
                    }

                    let sl_price = current_price * (1.0 + mr_params.stop_loss);
                    let tp_price = current_price * (1.0 + mr_params.exit_threshold);

                    return execute_entry(
                        pool,
                        oanda,
                        strategy,
                        &Direction::Long,
                        &strategy.max_position_size,
                        current_price,
                        sl_price,
                        Some(tp_price),
                        &format!(
                            "BelowMA: MA{}={:.5}, deviation={:.4}%",
                            mr_params.ma_period,
                            ma_value,
                            deviation_pct * 100.0
                        ),
                        open_positions,
                    )
                    .await;
                }
                _ => {}
            }
        }
        "trend_following" => {
            let tf_params = TrendFollowingParams {
                fast_period: params["fast_period"].as_u64().unwrap_or(10) as usize,
                slow_period: params["slow_period"].as_u64().unwrap_or(50) as usize,
                stop_loss: params["stop_loss"].as_f64().unwrap_or(-0.02),
                take_profit: params["take_profit"].as_f64(),
                regime_filter: false, // live path: regime gating handled by Elixir rules engine
            };

            let closes = buffer.closes();

            // Diagnostic: compute fast/slow MAs for logging
            if closes.len() >= tf_params.slow_period {
                let fast_ma: f64 = closes[closes.len() - tf_params.fast_period..]
                    .iter()
                    .sum::<f64>()
                    / tf_params.fast_period as f64;
                let slow_ma: f64 = closes[closes.len() - tf_params.slow_period..]
                    .iter()
                    .sum::<f64>()
                    / tf_params.slow_period as f64;
                let gap_pct = (fast_ma - slow_ma) / slow_ma * 100.0;
                let side = if fast_ma > slow_ma { "ABOVE" } else { "BELOW" };
                tracing::info!(
                    "[STATUS] TF {} {} | F{}={:.5} S{}={:.5} gap={:.4}% ({}) | buf={}",
                    strategy.instrument,
                    strategy.granularity,
                    tf_params.fast_period,
                    fast_ma,
                    tf_params.slow_period,
                    slow_ma,
                    gap_pct,
                    side,
                    closes.len(),
                );
            } else {
                tracing::info!(
                    "[STATUS] TF {} {} | buffer {}/{} — waiting for data",
                    strategy.instrument,
                    strategy.granularity,
                    closes.len(),
                    tf_params.slow_period,
                );
            }

            match trend_following::check_entry(&closes, &tf_params) {
                TFSignal::EnterLong { fast_ma, slow_ma } => {
                    tracing::info!(
                        "[SIGNAL] Trend following LONG on {} ({}): fast_ma={:.5}, slow_ma={:.5}",
                        strategy.instrument,
                        strategy.granularity,
                        fast_ma,
                        slow_ma
                    );

                    if let Some(gated) = entry_gate_report(rules, strategy, current_price) {
                        return Ok(Some(gated));
                    }

                    let sl_price = current_price * (1.0 + tf_params.stop_loss);
                    let tp_price = tf_params.take_profit.map(|tp| current_price * (1.0 + tp));

                    return execute_entry(
                        pool,
                        oanda,
                        strategy,
                        &Direction::Long,
                        &strategy.max_position_size,
                        current_price,
                        sl_price,
                        tp_price,
                        &format!("CrossAbove: fast_ma={:.5}, slow_ma={:.5}", fast_ma, slow_ma),
                        open_positions,
                    )
                    .await;
                }
                TFSignal::EnterShort { fast_ma, slow_ma } => {
                    tracing::info!(
                        "[SIGNAL] Trend following SHORT on {} ({}): fast_ma={:.5}, slow_ma={:.5}",
                        strategy.instrument,
                        strategy.granularity,
                        fast_ma,
                        slow_ma
                    );

                    if let Some(gated) = entry_gate_report(rules, strategy, current_price) {
                        return Ok(Some(gated));
                    }

                    let sl_price = current_price * (1.0 - tf_params.stop_loss);
                    let tp_price = tf_params.take_profit.map(|tp| current_price * (1.0 - tp));
                    let short_units = format!("-{}", strategy.max_position_size);

                    return execute_entry(
                        pool,
                        oanda,
                        strategy,
                        &Direction::Short,
                        &short_units,
                        current_price,
                        sl_price,
                        tp_price,
                        &format!("CrossBelow: fast_ma={:.5}, slow_ma={:.5}", fast_ma, slow_ma),
                        open_positions,
                    )
                    .await;
                }
                _ => {}
            }
        }
        _ => {}
    }
    Ok(None)
}

async fn execute_entry(
    pool: &PgPool,
    oanda: &OandaClient,
    strategy: &LiveStrategy,
    direction: &Direction,
    units: &str,
    current_price: f64,
    sl_price: f64,
    tp_price: Option<f64>,
    entry_reason: &str,
    open_positions: &mut HashMap<String, OpenPosition>,
) -> Result<Option<SignalReport>, Box<dyn std::error::Error + Send + Sync>> {
    let sl_str = format_price(&strategy.instrument, sl_price);
    let tp_str = tp_price.map(|p| format_price(&strategy.instrument, p));

    match oanda
        .create_market_order(
            &strategy.instrument,
            units,
            Some(&sl_str),
            tp_str.as_deref(),
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
                     entry_price, stop_loss_price, take_profit_price, entry_reason, status)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'open')"#,
            )
            .bind(strategy.id)
            .bind(&trade_id)
            .bind(&strategy.instrument)
            .bind(direction)
            .bind(units)
            .bind(fill_price)
            .bind(sl_price)
            .bind(tp_price)
            .bind(entry_reason)
            .execute(pool)
            .await?;

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
                    direction: *direction,
                    entry_price: fill_price,
                    units: units.to_string(),
                    stop_loss_state: StopLossState::initial_for_strategy_type(
                        &strategy.strategy_type,
                    ),
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
    pool: &PgPool,
    oanda: &OandaClient,
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

    match strategy.strategy_type.as_str() {
        "mean_reversion" => {
            // Exits are managed OANDA-side SL/TP orders; reconciler syncs DB.
            // No rust exit checks needed on this arm
            return Ok(vec![]);
        }
        "trend_following" => {
            let tf_params = TrendFollowingParams {
                fast_period: params["fast_period"].as_u64().unwrap_or(10) as usize,
                slow_period: params["slow_period"].as_u64().unwrap_or(50) as usize,
                stop_loss: params["stop_loss"].as_f64().unwrap_or(-0.02),
                take_profit: params["take_profit"].as_f64(),
                regime_filter: false, // live path: regime gating handled by Elixir rules engine
            };

            let is_long = positions_for_strategy[0].direction == Direction::Long;
            let closes = buffer.closes();

            match trend_following::check_exit(&closes, &tf_params, is_long) {
                TFSignal::ExitTrendReversal { fast_ma, slow_ma } => {
                    should_exit = true;
                    exit_reason = format!(
                        "TrendReversal: fast_ma={:.5}, slow_ma={:.5}",
                        fast_ma, slow_ma
                    );
                }
                _ => {}
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

            match oanda.close_trade(&trade_id, None).await {
                Ok(resp) => {
                    let fill_price = resp["orderFillTransaction"]["price"]
                        .as_str()
                        .and_then(|p| p.parse::<f64>().ok())
                        .unwrap_or(current_price);

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
                            exit_reason = $3, status = 'closed', updated_at = NOW()
                        WHERE oanda_trade_id = $4"#,
                    )
                    .bind(fill_price)
                    .bind(pnl)
                    .bind(&exit_reason)
                    .bind(&trade_id)
                    .execute(pool)
                    .await?;

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
    use uuid::Uuid;

    fn make_position(trade_id: &str, entry_price: f64) -> OpenPosition {
        OpenPosition {
            strategy_id: Uuid::nil(),
            trade_id: trade_id.to_string(),
            instrument: "EUR_USD".to_string(),
            direction: Direction::Long,
            entry_price,
            units: "1000".to_string(),
            stop_loss_state: StopLossState::Initial,
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
