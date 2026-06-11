use sqlx::PgPool;

use super::models::{UpsertAccount, WealthsimpleAccount, WealthsimplePosition};
use crate::brokers::client::BrokerClient;
use crate::brokers::{BrokerAccount, BrokerKind, BrokerStatus};
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
        let accounts = sqlx::query!(
            "SELECT id, account_type, account_number, currency, cash, market_value, total_equity, updated_at
             FROM wealthsimple_accounts ORDER BY id"
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|e| AppError::Internal(format!("DB error reading wealthsimple accounts: {}", e)))?;

        let mut result = Vec::with_capacity(accounts.len());
        for row in accounts {
            let positions = sqlx::query_as!(
                WealthsimplePosition,
                "SELECT id, account_id, symbol, shares, avg_cost, current_price, updated_at
                 FROM wealthsimple_positions WHERE account_id = $1 ORDER BY symbol",
                row.id
            )
            .fetch_all(&self.pool)
            .await
            .map_err(|e| {
                AppError::Internal(format!("DB error reading wealthsimple positions: {}", e))
            })?;

            result.push(WealthsimpleAccount {
                id: row.id,
                account_type: row.account_type,
                account_number: row.account_number,
                currency: row.currency,
                cash: row.cash,
                market_value: row.market_value,
                total_equity: row.total_equity,
                updated_at: row.updated_at,
                positions,
            });
        }
        Ok(result)
    }

    /// Replace the full account + positions list in a single transaction.
    pub async fn save_accounts(&self, accounts: &[UpsertAccount]) -> AppResult<()> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| AppError::Internal(format!("DB error starting transaction: {}", e)))?;

        // Cascade delete handles positions
        sqlx::query!("DELETE FROM wealthsimple_accounts")
            .execute(&mut *tx)
            .await
            .map_err(|e| {
                AppError::Internal(format!("DB error clearing wealthsimple accounts: {}", e))
            })?;

        for acct in accounts {
            let row = sqlx::query!(
                "INSERT INTO wealthsimple_accounts
                    (account_type, account_number, currency, cash, market_value, total_equity, updated_at)
                 VALUES ($1, $2, $3, $4, $5, $6, NOW())
                 RETURNING id",
                acct.account_type,
                acct.account_number,
                acct.currency,
                acct.cash,
                acct.market_value,
                acct.total_equity,
            )
            .fetch_one(&mut *tx)
            .await
            .map_err(|e| AppError::Internal(format!("DB error inserting wealthsimple account: {}", e)))?;

            for pos in &acct.positions {
                sqlx::query!(
                    "INSERT INTO wealthsimple_positions
                        (account_id, symbol, shares, avg_cost, current_price, updated_at)
                     VALUES ($1, $2, $3, $4, $5, NOW())",
                    row.id,
                    pos.symbol.to_uppercase(),
                    pos.shares,
                    pos.avg_cost,
                    pos.current_price,
                )
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
            sqlx::query!(
                "UPDATE wealthsimple_positions SET current_price = $1, updated_at = NOW() WHERE id = $2",
                price,
                position_id,
            )
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
