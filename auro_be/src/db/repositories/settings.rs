//! The settings people enter on Opus's Settings page (`settings` table):
//! each stored under the name its `.env` variable has (`OANDA_API_KEY`), a
//! secret one encrypted (`secrets`). Opus writes them; the engine reads them
//! when it starts (`Config`), ahead of `.env`.

use sqlx::PgPool;

/// Every stored setting, `(name, value as stored)`.
pub async fn load_all(pool: &PgPool) -> Result<Vec<(String, String)>, sqlx::Error> {
    sqlx::query_as("SELECT name, value FROM settings")
        .fetch_all(pool)
        .await
}
