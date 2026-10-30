use chrono::NaiveDate;
use sqlx::PgPool;

use crate::engine::financing::{BrokerCosts, FinancingModel, Overnight, PolicyRates};

/// Every policy-rate change point, as (currency, effective date, rate).
async fn policy_rows(pool: &PgPool) -> Result<Vec<(String, NaiveDate, f64)>, sqlx::Error> {
    sqlx::query_as(
        "SELECT currency, effective_date, rate FROM policy_rates ORDER BY currency, effective_date",
    )
    .fetch_all(pool)
    .await
}

/// The policy rates alone, for the live evaluator's `Carry` blocks (the
/// backtest gets the same rows through `load_model`).
pub async fn load_policy_rates(pool: &PgPool) -> Result<PolicyRates, sqlx::Error> {
    Ok(PolicyRates::new(policy_rows(pool).await?))
}

/// Each market's broker costs (`instruments.test_broker` → `brokers`),
/// under every name the market is known by (OANDA's, Questrade's,
/// Massive's), so a test finds it whatever the strategy calls it. A
/// market's own `spread_bps` stands in for its broker's fixed one; a broker
/// that fills at the bars' bid/ask (no `spread_bps`) keeps doing so.
async fn broker_rows(pool: &PgPool) -> Result<Vec<(String, BrokerCosts)>, sqlx::Error> {
    let rows: Vec<(String, String, String, Option<f64>, f64, bool)> = sqlx::query_as(
        "SELECT n.name, b.name, b.overnight_cost, \
                CASE WHEN b.spread_bps IS NULL THEN NULL \
                     ELSE COALESCE(i.spread_bps, b.spread_bps) END, \
                b.commission_bps, b.can_short \
         FROM instruments i \
         JOIN brokers b ON b.name = i.test_broker \
         CROSS JOIN LATERAL (VALUES (i.oanda_symbol), (i.questrade_symbol), (i.massive_ticker)) \
              AS n(name) \
         WHERE n.name IS NOT NULL",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(
            |(market, broker, overnight, spread_bps, commission_bps, can_short)| {
                let overnight = match overnight.as_str() {
                    "oanda_financing" => Overnight::OandaFinancing,
                    _ => Overnight::None,
                };
                (
                    market,
                    BrokerCosts {
                        broker,
                        overnight,
                        spread_bps,
                        commission_bps,
                        can_short,
                    },
                )
            },
        )
        .collect())
}

/// The full cost model: every policy-rate change point, every recorded
/// OANDA rate, and each market's broker costs. Small (hundreds of rows),
/// loaded once per backtest.
pub async fn load_model(pool: &PgPool) -> Result<FinancingModel, sqlx::Error> {
    let policy = policy_rows(pool).await?;

    let recorded: Vec<(String, NaiveDate, f64, f64)> = sqlx::query_as(
        "SELECT instrument, as_of, long_rate, short_rate FROM instrument_financing \
         ORDER BY instrument, as_of",
    )
    .fetch_all(pool)
    .await?;

    Ok(FinancingModel::new(policy, recorded).with_brokers(broker_rows(pool).await?))
}

/// Record OANDA's (long, short) annual financing rates for `as_of`,
/// overwriting an earlier snapshot of the same day. Returns rows written;
/// an OANDA name the master does not know is skipped with a warning, not
/// stored (the table requires the instrument id).
pub async fn upsert_instrument_financing(
    pool: &PgPool,
    as_of: NaiveDate,
    rates: &[(String, f64, f64)],
) -> Result<usize, sqlx::Error> {
    let mut tx = pool.begin().await?;
    let mut written = 0usize;
    for (instrument, long_rate, short_rate) in rates {
        let result = sqlx::query(
            "INSERT INTO instrument_financing \
                 (instrument, instrument_id, as_of, long_rate, short_rate) \
             SELECT $1, id, $2, $3, $4 FROM instruments WHERE oanda_symbol = $1 \
             ON CONFLICT (instrument, as_of) DO UPDATE \
             SET long_rate = EXCLUDED.long_rate, short_rate = EXCLUDED.short_rate, \
                 recorded_at = NOW()",
        )
        .bind(instrument)
        .bind(as_of)
        .bind(long_rate)
        .bind(short_rate)
        .execute(&mut *tx)
        .await?;
        match result.rows_affected() {
            0 => tracing::warn!(
                "Financing for {} not stored: not in the instruments table",
                instrument
            ),
            _ => written += 1,
        }
    }
    tx.commit().await?;
    Ok(written)
}
