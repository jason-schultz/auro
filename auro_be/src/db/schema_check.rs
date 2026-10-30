//! Startup schema check. Opus owns every migration
//! (opus/priv/repo/migrations); Auro only confirms that the tables it reads
//! and writes exist, so a missed `mix ecto.migrate` fails here, by name,
//! instead of at the first query hours later.

use sqlx::PgPool;

use crate::config::Mode;

/// Every table Auro touches, Rust-owned and Opus-owned alike.
pub const REQUIRED_TABLES: &[&str] = &[
    "account_snapshots",
    "candles",
    "instrument_financing",
    "instrument_unit_caps",
    "instruments",
    "kfold_validations",
    "live_strategies",
    "live_trades",
    "option_bars",
    "option_contracts",
    "option_quotes",
    "policy_rates",
    "questrade_tokens",
    "research_trials",
    "rules",
    "signal_events",
    "strategies",
    "strategy_configs",
    "strategy_evaluations",
    "trading_config",
    "validation_thresholds",
    "wealthsimple_accounts",
    "wealthsimple_positions",
];

/// Columns only the tester writes, as `table.column`: it refuses to start
/// without them, while the live process (which never writes them) is not
/// held up by a migration it doesn't need.
pub const TESTER_COLUMNS: &[&str] = &[
    "strategy_evaluations.rules_version",
    "brokers.name",
    "instruments.test_broker",
    "instruments.spread_bps",
];

/// Names in `required` that are not present in the public schema.
pub fn missing<'a>(required: &[&'a str], present: &[String]) -> Vec<&'a str> {
    required
        .iter()
        .copied()
        .filter(|t| !present.iter().any(|p| p == t))
        .collect()
}

pub async fn verify(pool: &PgPool, mode: Mode) -> Result<(), String> {
    let present: Vec<String> = sqlx::query_scalar(
        "SELECT table_name::text FROM information_schema.tables WHERE table_schema = 'public'",
    )
    .fetch_all(pool)
    .await
    .map_err(|e| format!("schema check query failed: {e}"))?;

    let gaps = missing(REQUIRED_TABLES, &present);
    if !gaps.is_empty() {
        return Err(format!(
            "database is missing tables {gaps:?}; run `mix ecto.migrate` in opus/ (Opus owns all migrations)"
        ));
    }

    if mode == Mode::Tester {
        let columns: Vec<String> = sqlx::query_scalar(
            "SELECT table_name::text || '.' || column_name::text \
             FROM information_schema.columns WHERE table_schema = 'public'",
        )
        .fetch_all(pool)
        .await
        .map_err(|e| format!("schema check query failed: {e}"))?;

        let gaps = missing(TESTER_COLUMNS, &columns);
        if !gaps.is_empty() {
            return Err(format!(
                "database is missing columns {gaps:?}; run `mix ecto.migrate` in opus/ (Opus owns all migrations)"
            ));
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::missing;

    #[test]
    fn reports_only_the_absent_tables() {
        let present = vec!["candles".to_string(), "rules".to_string()];
        assert_eq!(
            missing(&["candles", "live_trades", "rules"], &present),
            vec!["live_trades"]
        );
        assert!(missing(&["candles"], &present).is_empty());
    }
}
