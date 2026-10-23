//! Options what-if for the Opus page: one single-leg position in, the
//! expiry outcomes and the numbers a newcomer should look at out. Spot and
//! the risk-free rate are filled from storage when the caller leaves them
//! blank; everything else is `engine::options`.

use axum::extract::State;
use axum::Json;
use chrono::{NaiveDate, Utc};
use serde::Deserialize;

use crate::db::repositories::candles as candles_repo;
use crate::engine::options::scenarios::{analyze, Analysis, Input, Side};
use crate::engine::options::{years_to_expiry, OptionKind};
use crate::engine::types::Granularity;
use crate::error::{AppError, AppResult};
use crate::state::AppState;

fn one() -> f64 {
    1.0
}

#[derive(Debug, Deserialize)]
pub struct ScenariosRequest {
    pub underlying: String,
    /// "call" | "put"
    pub kind: String,
    pub side: Side,
    pub strike: f64,
    pub expiration: NaiveDate,
    /// Premium per share.
    pub premium: f64,
    #[serde(default = "one")]
    pub contracts: f64,
    /// Blank = the underlying's last stored daily close.
    pub spot: Option<f64>,
    /// Blank = solved from the premium.
    pub sigma: Option<f64>,
    /// Blank = the latest USD policy rate on file.
    pub rate: Option<f64>,
    #[serde(default)]
    pub div_yield: f64,
    /// Covered calls: what the shares cost. Blank = the spot.
    pub cost_basis: Option<f64>,
}

pub async fn scenarios(
    State(state): State<AppState>,
    Json(req): Json<ScenariosRequest>,
) -> AppResult<Json<Analysis>> {
    let kind = OptionKind::parse(&req.kind).ok_or_else(|| {
        AppError::BadRequest(format!("kind must be call or put, got {:?}", req.kind))
    })?;
    for (name, v) in [
        ("strike", req.strike),
        ("premium", req.premium),
        ("contracts", req.contracts),
    ] {
        if !(v.is_finite() && v > 0.0) {
            return Err(AppError::BadRequest(format!(
                "{name} must be a positive number"
            )));
        }
    }
    let underlying = req.underlying.trim().to_uppercase();
    let spot = match req.spot {
        Some(s) if s > 0.0 => s,
        _ => candles_repo::latest_close(&state.db, &underlying, Granularity::D)
            .await
            .map_err(AppError::Database)?
            .ok_or_else(|| {
                AppError::BadRequest(format!(
                    "no stored price for {underlying}; enter the spot price"
                ))
            })?,
    };
    let rate = match req.rate {
        Some(r) => r,
        None => latest_policy_rate(&state, "USD").await?.unwrap_or(0.0),
    };
    let t = years_to_expiry(Utc::now(), req.expiration);
    let input = Input {
        kind,
        side: req.side,
        spot,
        strike: req.strike,
        premium: req.premium,
        contracts: req.contracts,
        t,
        rate,
        div_yield: req.div_yield,
        sigma: req.sigma,
        cost_basis: req.cost_basis,
    };
    Ok(Json(analyze(&input)))
}

async fn latest_policy_rate(state: &AppState, currency: &str) -> AppResult<Option<f64>> {
    sqlx::query_scalar(
        "SELECT rate FROM policy_rates WHERE currency = $1 ORDER BY effective_date DESC LIMIT 1",
    )
    .bind(currency)
    .fetch_optional(&state.db)
    .await
    .map_err(AppError::Database)
}
