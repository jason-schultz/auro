use sqlx::PgPool;

use crate::engine::types::{Direction, OpenPosition, StopLossState};
use crate::state::AppState;

use super::format_price;
use super::risk_params;

async fn fetch_take_profit(db: &PgPool, strategy_id: &uuid::Uuid) -> Option<f64> {
    let params: Option<serde_json::Value> =
        sqlx::query_scalar("SELECT parameters FROM live_strategies WHERE id = $1")
            .bind(strategy_id)
            .fetch_optional(db)
            .await
            .ok()
            .flatten();

    params.and_then(|p| p.get("take_profit").and_then(|v| v.as_f64()))
}

async fn fetch_strategy_type(db: &PgPool, strategy_id: &uuid::Uuid) -> Option<String> {
    sqlx::query_scalar("SELECT strategy_type FROM live_strategies WHERE id = $1")
        .bind(strategy_id)
        .fetch_optional(db)
        .await
        .ok()
        .flatten()
}

fn calc_be_threshold(take_profit: f64) -> f64 {
    (take_profit * 0.4).max(0.010)
}

fn calc_trailing_threshold(take_profit: f64) -> f64 {
    (take_profit * 0.75).max(0.025)
}

pub(crate) async fn evaluate_trade_management(
    state: &AppState,
    position: &OpenPosition,
    current_price: f64,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Update MAE/MFE extremes and persist if a new extreme is hit.
    update_mae_mfe(state, position, current_price).await;

    // Skip SL management if not eligible or already at terminal state.
    // Trailing includes nil-TP strategies which open directly in this state.
    if matches!(
        position.stop_loss_state,
        StopLossState::NotApplicable | StopLossState::Trailing
    ) {
        return Ok(());
    }

    let take_profit = match fetch_take_profit(&state.db, &position.strategy_id).await {
        Some(tp) => tp,
        None => {
            tracing::warn!(
                "[MGMT] Could not fetch take_profit for strategy {}",
                position.strategy_id
            );
            return Ok(());
        }
    };

    // Compute % move from entry, direction-aware
    // Long: profit when price > entry. Short: profit when price < entry.
    let pct_in_profit = match position.direction {
        Direction::Long => (current_price - position.entry_price) / position.entry_price,
        Direction::Short => (position.entry_price - current_price) / position.entry_price,
    };

    match position.stop_loss_state {
        StopLossState::Initial => {
            // Move SL to breakeven (entry price) once trade is up to dynamic BE threshold
            let be_threshold = calc_be_threshold(take_profit);
            if pct_in_profit >= be_threshold {
                let sl_str = format_price(&position.instrument, position.entry_price);

                tracing::info!(
                    "[MGMT] {} {} ({}) up {:.2}% — moving SL to breakeven @ {}",
                    position.direction,
                    position.instrument,
                    position.trade_id,
                    pct_in_profit * 100.0,
                    sl_str
                );

                state
                    .oanda
                    .modify_trade_stop_loss(&position.trade_id, &sl_str)
                    .await?;

                // Update in-memory state
                let mut positions = state.live.open_positions.write().await;
                if let Some(p) = positions.get_mut(&position.trade_id) {
                    p.stop_loss_state = StopLossState::Breakeven;
                }
            }
        }
        StopLossState::Breakeven => {
            // Transition to trailing stop once trade is up to dynamic trailing threshold
            // This is scaled to TP so that tight-TP strategies reach trailing before TP is hit.
            let trailing_threshold = calc_trailing_threshold(take_profit);

            if pct_in_profit >= trailing_threshold {
                let strategy_type =
                    match fetch_strategy_type(&state.db, &position.strategy_id).await {
                        Some(strategy_type) => strategy_type,
                        None => {
                            tracing::warn!(
                                "[MGMT] Could not fetch strategy_type for strategy {}",
                                position.strategy_id
                            );
                            return Ok(());
                        }
                    };

                let Some(distance_price) = risk_params::trailing_distance_price(
                    state,
                    &position.instrument,
                    &strategy_type,
                    current_price,
                )
                .await
                else {
                    tracing::warn!(
                        "[MGMT] {} {} ({}) ATR trailing distance unavailable; keeping Breakeven",
                        position.direction,
                        position.instrument,
                        position.trade_id,
                    );
                    return Ok(());
                };

                let distance_str = format_price(&position.instrument, distance_price);

                tracing::info!(
                    "[MGMT] {} {} ({}) up {:.2}% — replacing SL with trailing @ distance {}",
                    position.direction,
                    position.instrument,
                    position.trade_id,
                    pct_in_profit * 100.0,
                    distance_str
                );

                state
                    .oanda
                    .replace_with_trailing_stop(&position.trade_id, &distance_str)
                    .await?;

                let mut positions = state.live.open_positions.write().await;
                if let Some(p) = positions.get_mut(&position.trade_id) {
                    p.stop_loss_state = StopLossState::Trailing;
                }
            }
        }
        StopLossState::Trailing | StopLossState::NotApplicable => {
            // Already handled by early return above; this arm is unreachable but
            // keeps the match exhaustive for future enum additions.
        }
    }

    Ok(())
}

/// Updates worst_price/best_price on the OpenPosition in-memory and writes MAE/MFE
/// to the DB whenever a new extreme is reached (not every tick — only on change).
async fn update_mae_mfe(state: &AppState, position: &OpenPosition, current_price: f64) {
    let (new_worst, new_best) = match position.direction {
        Direction::Long => (
            position.worst_price.min(current_price),
            position.best_price.max(current_price),
        ),
        Direction::Short => (
            position.worst_price.max(current_price),
            position.best_price.min(current_price),
        ),
    };

    let worst_changed = (new_worst - position.worst_price).abs() > f64::EPSILON;
    let best_changed = (new_best - position.best_price).abs() > f64::EPSILON;

    if !worst_changed && !best_changed {
        return;
    }

    // Update in-memory state first
    {
        let mut positions = state.live.open_positions.write().await;
        if let Some(p) = positions.get_mut(&position.trade_id) {
            p.worst_price = new_worst;
            p.best_price = new_best;
        }
    }

    // Compute MAE/MFE percentages
    let mae_pct = match position.direction {
        Direction::Long => (position.entry_price - new_worst) / position.entry_price,
        Direction::Short => (new_worst - position.entry_price) / position.entry_price,
    };
    let mfe_pct = match position.direction {
        Direction::Long => (new_best - position.entry_price) / position.entry_price,
        Direction::Short => (position.entry_price - new_best) / position.entry_price,
    };

    if let Err(e) = sqlx::query(
        "UPDATE live_trades SET mae_pct = $1, mfe_pct = $2, updated_at = NOW() \
         WHERE oanda_trade_id = $3 AND status = 'open'",
    )
    .bind(mae_pct)
    .bind(mfe_pct)
    .bind(&position.trade_id)
    .execute(&state.db)
    .await
    {
        tracing::warn!(
            "[MGMT] Failed to update MAE/MFE for {}: {}",
            position.trade_id,
            e
        );
    }
}
