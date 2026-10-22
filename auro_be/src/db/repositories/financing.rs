use chrono::NaiveDate;
use sqlx::PgPool;

use crate::engine::financing::FinancingModel;

/// The full financing model: every policy-rate change point and every
/// recorded OANDA rate. Small (hundreds of rows), loaded once per backtest.
pub async fn load_model(pool: &PgPool) -> Result<FinancingModel, sqlx::Error> {
    let policy: Vec<(String, NaiveDate, f64)> = sqlx::query_as(
        "SELECT currency, effective_date, rate FROM policy_rates ORDER BY currency, effective_date",
    )
    .fetch_all(pool)
    .await?;

    let recorded: Vec<(String, NaiveDate, f64, f64)> = sqlx::query_as(
        "SELECT instrument, as_of, long_rate, short_rate FROM instrument_financing \
         ORDER BY instrument, as_of",
    )
    .fetch_all(pool)
    .await?;

    Ok(FinancingModel::new(policy, recorded))
}

/// Record OANDA's (long, short) annual financing rates for `as_of`,
/// overwriting an earlier snapshot of the same day. Returns rows written.
pub async fn upsert_instrument_financing(
    pool: &PgPool,
    as_of: NaiveDate,
    rates: &[(String, f64, f64)],
) -> Result<usize, sqlx::Error> {
    let mut tx = pool.begin().await?;
    for (instrument, long_rate, short_rate) in rates {
        sqlx::query(
            "INSERT INTO instrument_financing (instrument, as_of, long_rate, short_rate) \
             VALUES ($1, $2, $3, $4) \
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
    }
    tx.commit().await?;
    Ok(rates.len())
}
