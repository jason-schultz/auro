//! Signal preview for the FE strategy editor: backtest a composite strategy
//! config over the most recent candle window and return its entries and exits.
//!
//! Runs `strategy::run_backtest` — the same runner the pipeline gates use — so
//! the markers include stop-loss and time-stop exits exactly as the backtest
//! takes them. A trade still open at the end of the window has no exit marker.
//!
//! Each signal carries its fill price, and an exit says why it closed
//! (`rule`, `stop_loss`, `hold_limit`). `bars` is the chart window: each
//! bar's OHLC and every component port's value on it (`"r.long": true`), so
//! a page can show which rule was true on which bar.

use axum::extract::State;
use axum::Json;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::db::repositories::candles as candles_repo;
use crate::engine::strategy::{bounded_window, run_backtest, Strategy};
use crate::engine::types::{Candle, Direction, ExitReason};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

#[derive(Deserialize)]
pub struct SignalPreviewRequest {
    /// Full composite strategy config (same JSON the editor saves).
    pub parameters: Value,
    /// How many recent bars to scan for signals (chart window size).
    pub count: Option<i64>,
}

pub async fn preview_signals(
    State(state): State<AppState>,
    Json(req): Json<SignalPreviewRequest>,
) -> AppResult<Json<Value>> {
    let strategy: Strategy = serde_json::from_value(req.parameters)
        .map_err(|e| AppError::BadRequest(format!("invalid composite config: {e}")))?;

    let count = req.count.unwrap_or(300).clamp(10, 1000);
    let warmup = strategy.warmup() as i64;

    let candles = candles_repo::load_recent_candles(
        &state.db,
        &strategy.instrument,
        strategy.granularity,
        (count + warmup).min(5000),
    )
    .await?;

    Ok(Json(preview(&candles, &strategy, count as usize)))
}

/// The preview body for `strategy` over `candles`, charting the last `count`.
fn preview(candles: &[Candle], strategy: &Strategy, count: usize) -> Value {
    let mut signals: Vec<Value> = Vec::new();
    let mut open_position: Option<Direction> = None;

    for trade in run_backtest(candles, strategy) {
        signals.push(signal_json(
            trade.entry_time,
            "entry",
            trade.direction,
            trade.entry_price,
            None,
        ));
        if trade.exit_reason == ExitReason::EndOfData {
            open_position = Some(trade.direction);
        } else {
            signals.push(signal_json(
                trade.exit_time,
                "exit",
                trade.direction,
                trade.exit_price,
                Some(exit_reason_str(trade.exit_reason)),
            ));
        }
    }

    json!({
        "instrument": strategy.instrument,
        "granularity": strategy.granularity.as_str(),
        "warmup": strategy.warmup(),
        "signals": signals,
        "open_position": open_position.map(direction_str),
        "bars": bars(candles, strategy, count),
    })
}

/// The last `count` bars with every port's value, keyed `"component.port"`.
/// A bar inside the warmup has no `ports`.
fn bars(candles: &[Candle], strategy: &Strategy, count: usize) -> Vec<Value> {
    let cap = strategy.granularity.buffer_capacity();
    let warmup = strategy.warmup();
    let from = candles.len().saturating_sub(count);

    (from..candles.len())
        .map(|i| {
            let c = &candles[i];
            let ports = (i >= warmup)
                .then(|| strategy.compute_ports(bounded_window(candles, i, cap)))
                .flatten()
                .map(|by_component| {
                    by_component
                        .into_iter()
                        .flat_map(|(name, ports)| {
                            ports
                                .into_iter()
                                .map(move |(port, on)| (format!("{name}.{port}"), on))
                        })
                        .collect::<std::collections::BTreeMap<String, bool>>()
                });
            json!({
                "time": c.time,
                "open": c.mid.open,
                "high": c.mid.high,
                "low": c.mid.low,
                "close": c.mid.close,
                "ports": ports,
            })
        })
        .collect()
}

fn signal_json(
    time: DateTime<Utc>,
    kind: &str,
    direction: Direction,
    price: f64,
    reason: Option<&str>,
) -> Value {
    json!({
        "time": time,
        "kind": kind,
        "direction": direction_str(direction),
        "price": price,
        "reason": reason,
    })
}

fn exit_reason_str(reason: ExitReason) -> &'static str {
    match reason {
        ExitReason::TrendReversal => "rule",
        ExitReason::StopLoss => "stop_loss",
        ExitReason::TimeStop => "hold_limit",
        ExitReason::EndOfData => "still_open",
    }
}

fn direction_str(direction: Direction) -> &'static str {
    match direction {
        Direction::Long => "long",
        Direction::Short => "short",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::{Duration, TimeZone};

    fn candles(closes: &[f64]) -> Vec<Candle> {
        closes
            .iter()
            .enumerate()
            .map(|(i, &c)| Candle {
                time: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap() + Duration::days(i as i64),
                mid: OHLC {
                    open: c,
                    high: c,
                    low: c,
                    close: c,
                },
                volume: 1,
                bid: None,
                ask: None,
            })
            .collect()
    }

    fn momentum() -> Strategy {
        serde_json::from_value(json!({
            "version": "1",
            "instrument": "TEST",
            "granularity": "D",
            "components": {"m": {"type": "Momentum", "params": {"lookback": 1}}},
            "entry": {"long": "m.up"},
            "exit": {"long": "m.down"},
            "stop": {"type": "FixedPct", "params": {"pct": -0.5}},
            "sizing": {"type": "RiskPct", "params": {"pct": 0.01}},
            "max_hold_bars": null
        }))
        .unwrap()
    }

    #[test]
    fn signals_carry_their_price_and_why_the_trade_closed() {
        let body = preview(
            &candles(&[100.0, 100.0, 101.0, 102.0, 101.0, 100.0]),
            &momentum(),
            4,
        );
        let signals = body["signals"].as_array().unwrap();

        assert_eq!(signals[0]["kind"], "entry");
        assert_eq!(signals[0]["price"], 101.0);
        assert_eq!(signals[1]["kind"], "exit");
        assert_eq!(signals[1]["price"], 101.0);
        assert_eq!(signals[1]["reason"], "rule");
    }

    #[test]
    fn bars_hold_the_window_with_each_rule_true_or_false() {
        let body = preview(
            &candles(&[100.0, 100.0, 101.0, 102.0, 101.0, 100.0]),
            &momentum(),
            4,
        );
        let bars = body["bars"].as_array().unwrap();

        assert_eq!(bars.len(), 4);
        assert_eq!(bars[0]["close"], 101.0);
        assert_eq!(bars[0]["ports"]["m.up"], true);
        assert_eq!(bars[2]["ports"]["m.down"], true);
    }
}
