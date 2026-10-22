use sqlx::PgPool;

use crate::engine::live::account_cache::AccountSnapshot;

pub(crate) async fn insert_account_snapshot(
    pool: &PgPool,
    snapshot: &AccountSnapshot,
    balance: f64,
    unrealized_pl: f64,
    open_position_count: i32,
) -> Result<(), sqlx::Error> {
    sqlx::query(
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
    .execute(pool)
    .await?;
    Ok(())
}
