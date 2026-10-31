//! `dividends` and `instruments.dividends_checked_at` (Opus migration
//! `20261030200000_dividends`): cash dividends from Massive, for testing
//! shares held at a broker with no overnight cost. The tests read them
//! through the cost model (`financing::load_model`).

use sqlx::PgPool;

use crate::brokers::massive::models::Dividend;
use crate::engine::instrument::InstrumentId;

/// Whether `instrument`'s dividends have ever been loaded.
pub async fn checked(pool: &PgPool, instrument: InstrumentId) -> Result<bool, sqlx::Error> {
    sqlx::query_scalar("SELECT dividends_checked_at IS NOT NULL FROM instruments WHERE id = $1")
        .bind(instrument)
        .fetch_one(pool)
        .await
}

/// Make `paid` the whole record for `instrument` (rows from an earlier
/// load that `paid` leaves out, such as a payment the bars already price
/// in, are removed) and stamp the instrument as checked, in one
/// transaction: a fund with no rows is then known to pay none. Returns the
/// rows written.
pub async fn store(
    pool: &PgPool,
    instrument: InstrumentId,
    paid: &[Dividend],
) -> Result<u64, sqlx::Error> {
    let mut tx = pool.begin().await?;
    sqlx::query("DELETE FROM dividends WHERE instrument_id = $1")
        .bind(instrument)
        .execute(&mut *tx)
        .await?;
    let mut written = 0;
    for d in paid {
        written += sqlx::query(
            "INSERT INTO dividends \
               (instrument_id, ex_date, pay_date, cash_amount, frequency, inserted_at, updated_at) \
             VALUES ($1, $2, $3, $4, $5, now(), now()) \
             ON CONFLICT (instrument_id, ex_date) DO UPDATE \
               SET pay_date = EXCLUDED.pay_date, cash_amount = EXCLUDED.cash_amount, \
                   frequency = EXCLUDED.frequency, updated_at = now()",
        )
        .bind(instrument)
        .bind(d.ex_dividend_date)
        .bind(d.pay_date)
        .bind(d.cash_amount)
        .bind(d.frequency)
        .execute(&mut *tx)
        .await?
        .rows_affected();
    }
    sqlx::query("UPDATE instruments SET dividends_checked_at = now() WHERE id = $1")
        .bind(instrument)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(written)
}
