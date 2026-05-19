use axum::extract::{Query, State};
use axum::Json;
use serde_json::{json, Value};
use std::collections::HashMap;

use crate::error::AppResult;
use crate::state::AppState;

#[derive(serde::Deserialize)]
pub struct PricingParams {
    pub instruments: String,
}

pub async fn get_account(State(state): State<AppState>) -> AppResult<Json<Value>> {
    let account = state.oanda.get_account().await?;

    Ok(Json(json!({
        "id": account.id,
        "currency": account.currency,
        "balance": account.balance,
        "unrealized_pl": account.unrealized_pl,
        "pl": account.pl,
        "open_trade_count": account.open_trade_count,
        "open_position_count": account.open_position_count,
        "margin_used": account.margin_used,
        "margin_available": account.margin_available,
    })))
}

pub async fn get_instruments(State(state): State<AppState>) -> AppResult<Json<Value>> {
    let instruments = state.oanda.get_instruments().await?;

    Ok(Json(json!({
        "instruments": instruments,
        "count": instruments.len(),
    })))
}

pub async fn get_pricing(
    State(state): State<AppState>,
    Query(params): Query<PricingParams>,
) -> AppResult<Json<Value>> {
    let instruments: Vec<&str> = params.instruments.split(',').collect();
    let prices = state.oanda.get_pricing(&instruments).await?;

    Ok(Json(json!({
        "prices": prices,
    })))
}

pub async fn get_open_trades(State(state): State<AppState>) -> AppResult<Json<Value>> {
    let resp = state.oanda.get_open_trades().await?;

    let trades = resp
        .get("trades")
        .and_then(|t| t.as_array())
        .cloned()
        .unwrap_or_default();

    let trade_ids: Vec<String> = trades
        .iter()
        .filter_map(|t| t.get("id").and_then(|v| v.as_str()).map(|s| s.to_string()))
        .collect();

    #[allow(clippy::type_complexity)]
    let db_rows: Vec<(
        String,
        uuid::Uuid,
        String,
        Option<f64>,
        Option<f64>,
        chrono::DateTime<chrono::Utc>,
    )> = if trade_ids.is_empty() {
        Vec::new()
    } else {
        sqlx::query_as(
                r#"SELECT lt.oanda_trade_id, lt.live_strategy_id, ls.granularity, lt.mfe_pct, lt.mae_pct, lt.entry_time
                   FROM live_trades lt
                   JOIN live_strategies ls ON ls.id = lt.live_strategy_id
                   WHERE lt.status = 'open' AND lt.oanda_trade_id = ANY($1)"#,
            )
            .bind(&trade_ids)
            .fetch_all(&state.db)
            .await
            .unwrap_or_default()
    };

    #[allow(clippy::type_complexity)]
    let db_map: HashMap<
        String,
        (
            uuid::Uuid,
            String,
            Option<f64>,
            Option<f64>,
            chrono::DateTime<chrono::Utc>,
        ),
    > = db_rows
        .into_iter()
        .map(|(tid, sid, gran, mfe, mae, entry_time)| (tid, (sid, gran, mfe, mae, entry_time)))
        .collect();

    let quote_map = state.live.last_quotes.read().await.clone();
    let open_pos_map = state.live.open_positions.read().await.clone();

    let enriched: Vec<Value> = trades
        .iter()
        .map(|t| {
            let trade_id = t
                .get("id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let instrument = t
                .get("instrument")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            let units = t
                .get("currentUnits")
                .and_then(|v| v.as_str())
                .or_else(|| t.get("initialUnits").and_then(|v| v.as_str()))
                .unwrap_or("0");

            let units_f = units.parse::<f64>().unwrap_or(0.0);
            let direction = if units_f >= 0.0 { "Long" } else { "Short" };

            let entry_price = t
                .get("price")
                .and_then(|v| v.as_str())
                .and_then(|s| s.parse::<f64>().ok())
                .unwrap_or(0.0);

            let current_price = quote_map.get(&instrument).map(|q| q.mid);
            let pnl_pct = current_price.map(|cp| {
                if direction == "Long" {
                    (cp - entry_price) / entry_price
                } else {
                    (entry_price - cp) / entry_price
                }
            });

            let stop_loss_price = t
                .get("stopLossOrder")
                .and_then(|v| v.get("price"))
                .and_then(|v| v.as_str())
                .and_then(|s| s.parse::<f64>().ok());

            let take_profit_price = t
                .get("takeProfitOrder")
                .and_then(|v| v.get("price"))
                .and_then(|v| v.as_str())
                .and_then(|s| s.parse::<f64>().ok());

            let stop_loss_state = open_pos_map
                .get(&trade_id)
                .map(|p| p.stop_loss_state.as_str().to_string())
                .unwrap_or_else(|| "NotApplicable".to_string());

            let (strategy_id, granularity, mfe_pct, mae_pct, entry_time) = db_map
                .get(&trade_id)
                .map(|(sid, gran, mfe, mae, et)| {
                    (
                        Some(sid.to_string()),
                        Some(gran.clone()),
                        *mfe,
                        *mae,
                        Some(et.to_rfc3339()),
                    )
                })
                .unwrap_or((None, None, None, None, None));

            json!({
                "id": trade_id,
                "instrument": instrument,
                "units": units,
                "direction": direction,
                "entry_price": entry_price,
                "current_price": current_price,
                "pnl_pct": pnl_pct,
                "mfe_pct": mfe_pct,
                "mae_pct": mae_pct,
                "stop_loss_state": stop_loss_state,
                "stop_loss_price": stop_loss_price,
                "take_profit_price": take_profit_price,
                "entry_time": entry_time,
                "strategy_id": strategy_id,
                "granularity": granularity,
            })
        })
        .collect();

    Ok(Json(json!({ "trades": enriched })))
}
