use chrono::{DateTime, Utc};

use crate::state::AppState;

#[derive(Debug, Clone)]
pub struct AccountSnapshot {
    pub nav: f64,
    pub currency: String,
    pub margin_available: f64,
    pub margin_used: f64,
    pub last_updated: DateTime<Utc>,
}

fn parse_f64(field: &str, value: &str) -> Option<f64> {
    match value.parse::<f64>() {
        Ok(v) => Some(v),
        Err(e) => {
            tracing::warn!(
                "[SIZING] failed to parse account {}='{}': {}",
                field,
                value,
                e
            );
            None
        }
    }
}

pub fn spawn_account_refresher(state: AppState) {
    tokio::spawn(async move {
        refresh_once(&state).await;

        let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
        interval.tick().await;
        loop {
            interval.tick().await;
            refresh_once(&state).await;
        }
    });
}

pub(crate) async fn refresh_once(state: &AppState) {
    let account = match state.oanda.get_account().await {
        Ok(account) => account,
        Err(e) => {
            tracing::warn!("[SIZING] account snapshot refresh failed: {}", e);
            return;
        }
    };

    let Some(balance) = parse_f64("balance", &account.balance) else {
        return;
    };
    let Some(unrealized_pl) = parse_f64("unrealizedPL", &account.unrealized_pl) else {
        return;
    };
    let Some(margin_available) = parse_f64("marginAvailable", &account.margin_available) else {
        return;
    };
    let Some(margin_used) = parse_f64("marginUsed", &account.margin_used) else {
        return;
    };

    let snapshot = AccountSnapshot {
        nav: balance + unrealized_pl,
        currency: account.currency,
        margin_available,
        margin_used,
        last_updated: Utc::now(),
    };

    let open_position_count = {
        let positions = state.live.open_positions.read().await;
        positions.len() as i32
    };

    let mut guard = state.live.account.write().await;
    *guard = Some(snapshot.clone());
    drop(guard);

    // TODO(retention): add rollup/retention policy for account_snapshots growth.
    if let Err(e) = sqlx::query(
        r#"INSERT INTO account_snapshots
            (timestamp, nav, balance, unrealized_pl, margin_used, margin_available, currency, open_position_count)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)"#,
    )
    .bind(snapshot.last_updated)
    .bind(snapshot.nav)
    .bind(balance)
    .bind(unrealized_pl)
    .bind(snapshot.margin_used)
    .bind(snapshot.margin_available)
    .bind(&snapshot.currency)
    .bind(open_position_count)
    .execute(&state.db)
    .await
    {
        tracing::warn!("[SIZING] failed to persist account snapshot: {}", e);
    }
}
