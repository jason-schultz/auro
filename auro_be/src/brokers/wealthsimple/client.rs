use sqlx::PgPool;

use super::models::{UpsertAccount, WealthsimpleAccount};
use crate::brokers::client::BrokerClient;
use crate::brokers::{BrokerAccount, BrokerKind, BrokerStatus};
use crate::db::repositories::instruments as instruments_repo;
use crate::error::{AppError, AppResult};

#[derive(Clone)]
pub struct WealthsimpleClient {
    pool: PgPool,
}

impl WealthsimpleClient {
    pub fn new(pool: &PgPool) -> Self {
        Self { pool: pool.clone() }
    }

    pub async fn list_accounts(&self) -> AppResult<Vec<WealthsimpleAccount>> {
        let mut accounts: Vec<WealthsimpleAccount> = sqlx::query_as(
            "SELECT id, account_type, account_number, currency, cash, market_value, total_equity, updated_at
             FROM wealthsimple_accounts ORDER BY id",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| AppError::Internal(format!("DB error reading wealthsimple accounts: {}", e)))?;

        for account in &mut accounts {
            account.positions = sqlx::query_as(
                "SELECT id, account_id, symbol, shares, avg_cost, current_price, updated_at
                 FROM wealthsimple_positions WHERE account_id = $1 ORDER BY symbol",
            )
            .bind(account.id)
            .fetch_all(&self.pool)
            .await
            .map_err(|e| {
                AppError::Internal(format!("DB error reading wealthsimple positions: {}", e))
            })?;
        }
        Ok(accounts)
    }

    /// Replace the full account + positions list in a single transaction.
    pub async fn save_accounts(&self, accounts: &[UpsertAccount]) -> AppResult<()> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| AppError::Internal(format!("DB error starting transaction: {}", e)))?;

        // Cascade delete handles positions
        sqlx::query("DELETE FROM wealthsimple_accounts")
            .execute(&mut *tx)
            .await
            .map_err(|e| {
                AppError::Internal(format!("DB error clearing wealthsimple accounts: {}", e))
            })?;

        for acct in accounts {
            let account_id: i32 = sqlx::query_scalar(
                "INSERT INTO wealthsimple_accounts
                    (account_type, account_number, currency, cash, market_value, total_equity, updated_at)
                 VALUES ($1, $2, $3, $4, $5, $6, NOW())
                 RETURNING id",
            )
            .bind(&acct.account_type)
            .bind(&acct.account_number)
            .bind(&acct.currency)
            .bind(acct.cash)
            .bind(acct.market_value)
            .bind(acct.total_equity)
            .fetch_one(&mut *tx)
            .await
            .map_err(|e| AppError::Internal(format!("DB error inserting wealthsimple account: {}", e)))?;

            for pos in &acct.positions {
                sqlx::query(sqlx::AssertSqlSafe(format!(
                    "INSERT INTO wealthsimple_positions \
                        (account_id, symbol, instrument_id, shares, avg_cost, current_price, \
                         updated_at) \
                     VALUES ($1, $2, {}, $3, $4, $5, NOW())",
                    instruments_repo::id_for_name_sql("$2")
                )))
                .bind(account_id)
                .bind(pos.symbol.to_uppercase())
                .bind(pos.shares)
                .bind(pos.avg_cost)
                .bind(pos.current_price)
                .execute(&mut *tx)
                .await
                .map_err(|e| {
                    AppError::Internal(format!("DB error inserting wealthsimple position: {}", e))
                })?;
            }
        }

        tx.commit().await.map_err(|e| {
            AppError::Internal(format!("DB error committing wealthsimple data: {}", e))
        })?;

        Ok(())
    }

    /// Update current_price for a list of (position_id, price) pairs.
    pub async fn update_position_prices(&self, updates: &[(i32, f64)]) -> AppResult<()> {
        for (position_id, price) in updates {
            sqlx::query(
                "UPDATE wealthsimple_positions SET current_price = $1, updated_at = NOW() WHERE id = $2",
            )
            .bind(*price)
            .bind(*position_id)
            .execute(&self.pool)
            .await
            .map_err(|e| {
                AppError::Internal(format!("DB error updating position price {}: {}", position_id, e))
            })?;
        }
        Ok(())
    }
}

impl BrokerClient for WealthsimpleClient {
    async fn broker_status(&mut self) -> BrokerStatus {
        let accounts = match self.list_accounts().await {
            Err(e) => {
                return BrokerStatus {
                    broker: BrokerKind::Wealthsimple,
                    display_name: "Wealthsimple",
                    connected: false,
                    error: Some(e.to_string()),
                    accounts: vec![],
                }
            }
            Ok(a) => a,
        };

        if accounts.is_empty() {
            return BrokerStatus {
                broker: BrokerKind::Wealthsimple,
                display_name: "Wealthsimple",
                connected: false,
                error: None,
                accounts: vec![],
            };
        }

        let broker_accounts = accounts
            .into_iter()
            .map(|a| BrokerAccount {
                id: a.id.to_string(),
                name: match &a.account_number {
                    Some(n) => format!("{} ({})", a.account_type, n),
                    None => a.account_type.clone(),
                },
                account_type: a.account_type,
                currency: a.currency,
                cash: a.cash,
                market_value: a.market_value,
                total_equity: a.total_equity,
                buying_power: None,
                paper: false,
            })
            .collect();

        BrokerStatus {
            broker: BrokerKind::Wealthsimple,
            display_name: "Wealthsimple",
            connected: true,
            error: None,
            accounts: broker_accounts,
        }
    }
}
