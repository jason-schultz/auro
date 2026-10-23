//! Questrade's identity for a listing in the master: its numeric symbol id,
//! which every market-data call takes, and the exchange and currency it
//! reports. Looked up once per listing and recorded on the `instruments`
//! row, so the nightly feeds never search by name again.

use sqlx::PgPool;

use super::client::QuestradeClient;
use crate::db::repositories::instruments as instruments_repo;
use crate::engine::instrument::Instrument;
use crate::error::{AppError, AppResult};

/// What Questrade reported for one spelling.
#[derive(Debug, Clone, PartialEq)]
pub struct QuestradeIdentity {
    pub symbol_id: i64,
    pub exchange: String,
    pub currency: String,
}

/// Outcome of an enrich pass over the master.
#[derive(Debug, Default, serde::Serialize)]
pub struct EnrichReport {
    pub resolved: usize,
    /// `(label, reason)` per listing Questrade could not identify.
    pub failed: Vec<(String, String)>,
}

/// The Questrade symbol id for `instrument`: the recorded one, or a lookup
/// that is recorded before returning. Errors if the listing has no
/// Questrade spelling.
pub async fn resolve_symbol_id(
    client: &mut QuestradeClient,
    pool: &PgPool,
    instrument: &Instrument,
) -> AppResult<i64> {
    if let Some(id) = instrument.questrade_symbol_id {
        return Ok(id);
    }
    let identity = lookup(client, instrument).await?;
    instruments_repo::record_questrade_identity(
        pool,
        instrument.id,
        identity.symbol_id,
        &identity.exchange,
        &identity.currency,
    )
    .await?;
    tracing::info!(
        "Recorded Questrade identity for {}: symbolId={} {} {}",
        instrument.label(),
        identity.symbol_id,
        identity.exchange,
        identity.currency
    );
    Ok(identity.symbol_id)
}

/// Ask Questrade who `instrument` is, by its Questrade spelling.
pub async fn lookup(
    client: &mut QuestradeClient,
    instrument: &Instrument,
) -> AppResult<QuestradeIdentity> {
    let symbol = instrument.questrade_symbol.as_deref().ok_or_else(|| {
        AppError::BadRequest(format!("{} has no Questrade symbol", instrument.label()))
    })?;
    let symbol_id = client.search_symbol(symbol).await?;
    let detail = client
        .get_symbols(&[symbol_id])
        .await?
        .into_iter()
        .next()
        .ok_or_else(|| {
            AppError::Internal(format!(
                "Questrade returned no detail for {symbol} (symbolId={symbol_id})"
            ))
        })?;
    Ok(QuestradeIdentity {
        symbol_id,
        exchange: detail.listing_exchange,
        currency: detail.currency,
    })
}

/// Identify every listing with a Questrade spelling and no recorded id
/// (every such listing when `all`), recording each as it is found. A
/// listing Questrade cannot identify is reported, not fatal.
pub async fn enrich(
    client: &mut QuestradeClient,
    pool: &PgPool,
    all: bool,
) -> AppResult<EnrichReport> {
    let pending = instruments_repo::questrade_unresolved(pool, all).await?;
    let mut report = EnrichReport::default();
    for instrument in &pending {
        match lookup(client, instrument).await {
            Ok(identity) => {
                instruments_repo::record_questrade_identity(
                    pool,
                    instrument.id,
                    identity.symbol_id,
                    &identity.exchange,
                    &identity.currency,
                )
                .await?;
                report.resolved += 1;
            }
            Err(e) => {
                tracing::warn!("Questrade could not identify {}: {}", instrument.label(), e);
                report.failed.push((instrument.label(), e.to_string()));
            }
        }
    }
    Ok(report)
}
