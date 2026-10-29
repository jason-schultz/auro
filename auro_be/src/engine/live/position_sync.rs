//! Keep `open_positions` in step with OANDA, the ground truth.
//!
//! Every minute the engine reads OANDA's open trades and corrects its map:
//!
//! - a position OANDA no longer holds (closed at OANDA while the Opus
//!   reconciler's DELETE didn't reach this engine) is dropped, so it stops
//!   blocking its strategy and counting against the limits;
//! - a trade OANDA holds with an open `live_trades` row but missing from the
//!   map (a pass that ended in an error before applying its changes) is
//!   tracked again, so its exits run and no duplicate opens;
//! - a trade with no row at all is listed as untracked (health reports it and
//!   Opus raises an alert): only its own stop protects it.
//!
//! The first successful sync (or the startup prefill) also lets entries start
//! (`LiveState::positions_known`).
//!
//! Positions that appeared or vanished during the OANDA call are left for the
//! next sync: only what was in the map before the call can be dropped, and
//! only what was missing before it can be added, so a trade opened or closed
//! by an evaluation in the meantime is never undone.

use std::collections::HashSet;
use std::time::Duration;

use crate::state::AppState;

use super::prefill;

const SYNC_EVERY: Duration = Duration::from_secs(60);

pub fn spawn_position_sync(state: AppState) {
    super::spawn_supervised("position sync", move || {
        let state = state.clone();
        async move {
            let mut interval = tokio::time::interval(SYNC_EVERY);
            loop {
                interval.tick().await;
                sync_once(&state).await;
            }
        }
    });
}

pub(crate) async fn sync_once(state: &AppState) {
    let before: HashSet<String> = state
        .live
        .open_positions
        .read()
        .await
        .keys()
        .cloned()
        .collect();

    let found = match prefill::oanda_positions(&state.db, &state.oanda).await {
        Ok(found) => found,
        Err(e) => {
            tracing::warn!("[SYNC] OANDA open trades unavailable; positions unchanged: {e}");
            return;
        }
    };

    let untracked = {
        let mut positions = state.live.open_positions.write().await;

        for gone in before.iter().filter(|id| !found.ids.contains(*id)) {
            if positions.remove(gone).is_some() {
                tracing::warn!("[SYNC] dropped position {gone}: OANDA no longer has it open");
            }
        }
        for (id, position) in &found.tracked {
            if !before.contains(id) && !positions.contains_key(id) {
                tracing::warn!(
                    "[SYNC] tracking {} {} trade {id} again: OANDA and the database have it open",
                    position.instrument,
                    position.granularity
                );
                positions.insert(id.clone(), position.clone());
            }
        }
        // A trade kept in memory without a row (its row failed to write)
        // is already being managed; only the rest are untracked.
        found
            .untracked
            .into_iter()
            .filter(|t| !positions.contains_key(&t.id))
            .collect::<Vec<_>>()
    };

    for t in &untracked {
        tracing::error!(
            "[UNTRACKED] OANDA has trade {} ({} {} units) that Auro has no record of; only its stop protects it",
            t.id,
            t.instrument,
            t.units
        );
    }
    *state.live.untracked_trades.write().await = untracked;
    *state.live.positions_known.write().await = true;
}
