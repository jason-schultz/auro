//! Options what-if for the Opus page: one single-leg position (or several
//! legs as one structure) in, the expiry outcomes and the numbers a
//! newcomer should look at out. Spot (the newest option quote's, else the
//! last daily close) and the risk-free rate are filled from storage when the
//! caller leaves them blank; everything else is `engine::options`.

use axum::extract::State;
use axum::Json;
use chrono::{NaiveDate, Utc};
use serde::{Deserialize, Serialize};

use crate::db::repositories::candles as candles_repo;
use crate::db::repositories::options as options_repo;
use crate::engine::options::scenarios::{
    analyze, analyze_structure, Analysis, Input, Leg, Side, Structure,
};
use crate::engine::options::{expiry_window, strike_band, years_to_expiry, OptionKind};
use crate::engine::types::Granularity;
use crate::error::{AppError, AppResult};
use crate::state::AppState;

/// Longest expiry window a chain request may ask for; the free Massive plan
/// serves roughly two years, and nothing further out is liquid anyway.
pub const MAX_DAYS_TO_EXPIRY: i64 = 800;

fn default_max_days_to_expiry() -> i64 {
    60
}

fn default_strike_band_pct() -> f64 {
    0.15
}

/// Which part of a chain an endpoint works on: expiries from today out to
/// `max_days_to_expiry` calendar days, strikes within `strike_band_pct` of
/// the spot. Flattened into the Massive and Questrade request bodies.
#[derive(Debug, Clone, Copy, Deserialize)]
pub struct ChainWindow {
    #[serde(default = "default_max_days_to_expiry")]
    pub max_days_to_expiry: i64,
    #[serde(default = "default_strike_band_pct")]
    pub strike_band_pct: f64,
}

impl ChainWindow {
    pub fn validate(&self) -> AppResult<()> {
        if !(0.0..=1.0).contains(&self.strike_band_pct) {
            return Err(AppError::BadRequest(format!(
                "strike_band_pct must be in 0..=1, got {}",
                self.strike_band_pct
            )));
        }
        if !(1..=MAX_DAYS_TO_EXPIRY).contains(&self.max_days_to_expiry) {
            return Err(AppError::BadRequest(format!(
                "max_days_to_expiry must be in 1..={MAX_DAYS_TO_EXPIRY}, got {}",
                self.max_days_to_expiry
            )));
        }
        Ok(())
    }

    /// The inclusive expiry window and strike band for `today` and `spot`.
    pub fn bounds(&self, today: NaiveDate, spot: f64) -> ((NaiveDate, NaiveDate), (f64, f64)) {
        (
            expiry_window(today, self.max_days_to_expiry),
            strike_band(spot, self.strike_band_pct),
        )
    }
}

fn one() -> f64 {
    1.0
}

#[derive(Debug, Deserialize)]
pub struct ScenariosRequest {
    pub underlying: String,
    /// "call" | "put". Required unless `legs` is given.
    pub kind: Option<String>,
    pub side: Option<Side>,
    pub strike: Option<f64>,
    pub expiration: NaiveDate,
    /// Premium per share. Required unless `legs` is given.
    pub premium: Option<f64>,
    #[serde(default = "one")]
    pub contracts: f64,
    /// Several legs on the same underlying and expiry, analysed as one
    /// structure (a spread, an iron condor). Replaces the single-leg fields.
    #[serde(default)]
    pub legs: Vec<LegRequest>,
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

#[derive(Debug, Deserialize)]
pub struct LegRequest {
    /// "call" | "put"
    pub kind: String,
    pub side: Side,
    pub strike: f64,
    /// Premium per share.
    pub premium: f64,
    #[serde(default = "one")]
    pub contracts: f64,
    /// Blank = solved from the premium.
    pub sigma: Option<f64>,
}

/// One leg analysed in full, or several summed into a structure.
#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum ScenariosResponse {
    Single(Box<Analysis>),
    Structure(Structure),
}

fn parse_kind(kind: &str) -> AppResult<OptionKind> {
    OptionKind::parse(kind)
        .ok_or_else(|| AppError::BadRequest(format!("kind must be call or put, got {kind:?}")))
}

fn positive(name: &str, v: Option<f64>) -> AppResult<f64> {
    match v {
        Some(v) if v.is_finite() && v > 0.0 => Ok(v),
        _ => Err(AppError::BadRequest(format!(
            "{name} must be a positive number"
        ))),
    }
}

pub async fn scenarios(
    State(state): State<AppState>,
    Json(req): Json<ScenariosRequest>,
) -> AppResult<Json<ScenariosResponse>> {
    let underlying = req.underlying.trim().to_uppercase();
    let spot = match req.spot {
        Some(s) if s > 0.0 => s,
        _ => stored_spot(&state, &underlying).await?,
    };
    let rate = match req.rate {
        Some(r) => r,
        None => latest_policy_rate(&state, "USD").await?.ok_or_else(|| {
            AppError::BadRequest("no USD policy rate stored; enter the risk-free rate".into())
        })?,
    };
    let t = years_to_expiry(Utc::now(), req.expiration);

    if !req.legs.is_empty() {
        let legs = req
            .legs
            .iter()
            .map(|l| {
                Ok(Leg {
                    kind: parse_kind(&l.kind)?,
                    side: l.side,
                    strike: positive("strike", Some(l.strike))?,
                    premium: positive("premium", Some(l.premium))?,
                    contracts: positive("contracts", Some(l.contracts))?,
                    sigma: l.sigma,
                })
            })
            .collect::<AppResult<Vec<Leg>>>()?;
        return Ok(Json(ScenariosResponse::Structure(analyze_structure(
            &legs,
            spot,
            t,
            rate,
            req.div_yield,
        ))));
    }

    let kind = parse_kind(req.kind.as_deref().unwrap_or_default())?;
    let side = req
        .side
        .ok_or_else(|| AppError::BadRequest("side is required".into()))?;
    let input = Input {
        kind,
        side,
        spot,
        strike: positive("strike", req.strike)?,
        premium: positive("premium", req.premium)?,
        contracts: positive("contracts", Some(req.contracts))?,
        t,
        rate,
        div_yield: req.div_yield,
        sigma: req.sigma,
        cost_basis: req.cost_basis,
    };
    Ok(Json(ScenariosResponse::Single(Box::new(analyze(&input)))))
}

/// The spot the newest stored option quote on `underlying` was taken
/// against (snapshots run through the session), else the last daily close.
async fn stored_spot(state: &AppState, underlying: &str) -> AppResult<f64> {
    if let Some(spot) = options_repo::latest_quote_spot(&state.db, underlying)
        .await
        .map_err(AppError::Database)?
    {
        return Ok(spot);
    }
    candles_repo::latest_close(&state.db, underlying, Granularity::D)
        .await
        .map_err(AppError::Database)?
        .ok_or_else(|| {
            AppError::BadRequest(format!(
                "no stored price for {underlying}; enter the spot price"
            ))
        })
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

#[cfg(test)]
mod tests {
    use super::*;

    fn window(max_days_to_expiry: i64, strike_band_pct: f64) -> ChainWindow {
        ChainWindow {
            max_days_to_expiry,
            strike_band_pct,
        }
    }

    #[test]
    fn chain_window_is_validated() {
        assert!(window(60, 0.15).validate().is_ok());
        assert!(window(60, 1.5).validate().is_err());
        assert!(window(0, 0.15).validate().is_err());
        assert!(window(MAX_DAYS_TO_EXPIRY + 1, 0.15).validate().is_err());
    }

    #[test]
    fn chain_window_fields_default_when_flattened() {
        #[derive(Deserialize)]
        struct Body {
            underlying: String,
            #[serde(flatten)]
            window: ChainWindow,
        }
        let body: Body = serde_json::from_str(r#"{"underlying":"SPY"}"#).unwrap();
        assert_eq!(body.underlying, "SPY");
        assert_eq!(body.window.max_days_to_expiry, 60);
        assert_eq!(body.window.strike_band_pct, 0.15);
        let body: Body =
            serde_json::from_str(r#"{"underlying":"SPY","max_days_to_expiry":45}"#).unwrap();
        assert_eq!(body.window.max_days_to_expiry, 45);
    }

    #[test]
    fn scenarios_request_takes_legs_or_a_single_leg() {
        // The shape Opus sends for a paper trade: no single-leg fields.
        let req: ScenariosRequest = serde_json::from_str(
            r#"{"underlying":"QQQ","expiration":"2026-12-04","spot":615.0,
                "legs":[{"kind":"put","side":"buy","strike":560.0,"premium":2.06,"contracts":1,"sigma":0.2},
                        {"kind":"put","side":"sell","strike":590.0,"premium":5.0,"contracts":1,"sigma":null}]}"#,
        )
        .unwrap();
        assert_eq!(req.legs.len(), 2);
        assert_eq!(req.legs[1].side, Side::Sell);
        assert!(req.kind.is_none() && req.strike.is_none());

        // The workbench's single leg still parses, with no legs.
        let req: ScenariosRequest = serde_json::from_str(
            r#"{"underlying":"SPY","kind":"put","side":"sell","strike":640.0,
                "premium":6.4,"expiration":"2026-12-04"}"#,
        )
        .unwrap();
        assert!(req.legs.is_empty());
        assert_eq!(req.strike, Some(640.0));
    }
}
