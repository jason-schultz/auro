use sqlx::PgPool;

use super::instruments as instruments_repo;
use crate::engine::types::{SignalAction, SignalReport};

pub async fn record_signal_event(pool: &PgPool, report: &SignalReport) -> Result<(), sqlx::Error> {
    let action = signal_action_label(&report.action);
    let payload = serde_json::json!({
        "strategy_id": report.strategy_id,
        "strategy_type": report.strategy_type,
        "instrument": report.instrument,
        "granularity": report.granularity.as_str(),
        "action": action,
        "price": report.price,
        "reason": report.reason,
        "oanda_trade_id": report.oanda_trade_id,
        "timestamp": chrono::Utc::now(),
    });
    let payload_text = payload.to_string();

    sqlx::query(sqlx::AssertSqlSafe(format!(
        "INSERT INTO signal_events \
            (strategy_id, strategy_type, instrument, instrument_id, granularity, action, \
             price, reason, oanda_trade_id, payload) \
         VALUES ($1, $2, $3, {}, $4, $5, $6, $7, $8, $9)",
        instruments_repo::id_for_name_sql("$3")
    )))
    .bind(report.strategy_id)
    .bind(&report.strategy_type)
    .bind(&report.instrument)
    .bind(report.granularity.as_str())
    .bind(action)
    .bind(report.price)
    .bind(&report.reason)
    .bind(&report.oanda_trade_id)
    .bind(payload)
    .execute(pool)
    .await?;

    sqlx::query("SELECT pg_notify('signal_event', $1)")
        .bind(payload_text)
        .execute(pool)
        .await?;

    Ok(())
}

fn signal_action_label(action: &SignalAction) -> &'static str {
    match action {
        SignalAction::OpenedLong => "opened_long",
        SignalAction::OpenedShort => "opened_short",
        SignalAction::ClosedLong => "closed_long",
        SignalAction::ClosedShort => "closed_short",
        SignalAction::EntryRejected => "entry_rejected",
        SignalAction::ExitConditionsNotMet => "exit_conditions_not_met",
    }
}
