use crate::db::repositories::live_trades as live_trades_repo;
use crate::engine::types::{Direction, OpenPosition};
use crate::state::AppState;

/// Updates worst_price/best_price on the OpenPosition in-memory and writes MAE/MFE
/// to the DB whenever a new extreme is reached (not every tick — only on change).
pub(crate) async fn update_mae_mfe(state: &AppState, position: &OpenPosition, current_price: f64) {
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

    // Written in the background so a slow database never holds up the
    // quote loop that every instrument's price goes through. The update
    // keeps the larger value, so writes landing out of order are harmless.
    let (db, trade_id) = (state.db.clone(), position.trade_id.clone());
    tokio::spawn(async move {
        if let Err(e) = live_trades_repo::record_excursions(&db, &trade_id, mae_pct, mfe_pct).await
        {
            tracing::warn!("[MGMT] Failed to update MAE/MFE for {}: {}", trade_id, e);
        }
    });
}
