use axum::extract::{Path, Query, State};
use axum::Json;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::engine::indicators;
use crate::engine::types::{BollingerBands, Granularity};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

#[derive(Deserialize)]
pub struct IndicatorParams {
    #[serde(default = "default_adx_period")]
    pub adx_period: usize,
    #[serde(default = "default_bollinger_period")]
    pub bollinger_period: usize,
    #[serde(default = "default_bollinger_std")]
    pub bollinger_std: f64,
    #[serde(default = "default_atr_period")]
    pub atr_period: usize,
    #[serde(default = "default_ma_period")]
    pub ma_period: usize,
}

fn default_adx_period() -> usize {
    14
}
fn default_bollinger_period() -> usize {
    20
}
fn default_bollinger_std() -> f64 {
    2.0
}
fn default_atr_period() -> usize {
    14
}
fn default_ma_period() -> usize {
    20
}

#[derive(Serialize)]
pub struct IndicatorResponse {
    pub instrument: String,
    pub granularity: Granularity,
    pub buffer_size: usize,
    pub last_close: Option<f64>,
    pub last_close_time: Option<DateTime<Utc>>,
    pub current_mid: f64,
    pub indicators: IndicatorScalars,
}

#[derive(Serialize)]
pub struct IndicatorScalars {
    pub adx: Option<f64>,
    pub atr_pct: Option<f64>,
    pub ma_deviation_pct: Option<f64>,
    pub bollinger: Option<BollingerBands>,
}

pub async fn get_indicators(
    Path((instrument, granularity_str)): Path<(String, String)>,
    Query(params): Query<IndicatorParams>,
    State(state): State<AppState>,
) -> AppResult<Json<IndicatorResponse>> {
    let granularity: Granularity = granularity_str
        .parse()
        .map_err(|e| AppError::BadRequest(format!("invalid granularity: {}", e)))?;

    let buffer = {
        let buffers = state.live.buffers.read().await;
        buffers.get(&(instrument.clone(), granularity)).cloned()
    };

    let buffer = buffer.ok_or_else(|| {
        AppError::NotFound(format!(
            "No buffer for {} {} \u{2014} ensure a strategy is enabled and prefilled",
            instrument, granularity
        ))
    })?;

    let candles = &buffer.candles;
    let last_candle = candles.last();

    let scalars = IndicatorScalars {
        adx: indicators::adx(candles, params.adx_period),
        atr_pct: indicators::atr_pct(candles, params.atr_period),
        ma_deviation_pct: indicators::ma_deviation_pct(candles, params.ma_period),
        bollinger: indicators::bollinger(candles, params.bollinger_period, params.bollinger_std),
    };

    Ok(Json(IndicatorResponse {
        instrument,
        granularity,
        buffer_size: candles.len(),
        last_close: last_candle.map(|c| c.close),
        last_close_time: last_candle.map(|c| c.time),
        current_mid: buffer.current_mid,
        indicators: scalars,
    }))
}
