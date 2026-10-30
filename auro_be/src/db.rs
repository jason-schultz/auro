use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;

pub mod repositories;
pub mod schema_check;

pub async fn create_pool(database_url: &str, max_connections: u32) -> Result<PgPool, sqlx::Error> {
    let pool = PgPoolOptions::new()
        .max_connections(max_connections)
        .connect(database_url)
        .await?;

    tracing::info!("Connected to PostgreSQL (pool of {max_connections})");

    // Opus owns all migrations; refuse to start against a database that is
    // missing anything Auro needs rather than failing at the first query.
    if let Err(msg) = schema_check::verify(&pool).await {
        return Err(sqlx::Error::Configuration(msg.into()));
    }

    tracing::info!("Schema check passed");

    Ok(pool)
}
