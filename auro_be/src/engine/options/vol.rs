//! Volatility inputs for the screens: what the underlying actually did
//! (realized vol, several estimators) against what the options price in
//! (implied vol, ranked against its own history). The gap between the two
//! is the premium a seller is paid for.
//!
//! All estimators are annualized with `TRADING_DAYS` and use the
//! population form, matching the project's signal-math convention.

use crate::engine::types::Candle;

pub const TRADING_DAYS: f64 = 252.0;

/// Natural-log close-to-close returns; one shorter than the input.
pub fn log_returns(closes: &[f64]) -> Vec<f64> {
    closes.windows(2).map(|w| (w[1] / w[0]).ln()).collect()
}

fn population_stdev(xs: &[f64]) -> Option<f64> {
    if xs.len() < 2 {
        return None;
    }
    let n = xs.len() as f64;
    let mean = xs.iter().sum::<f64>() / n;
    Some((xs.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / n).sqrt())
}

/// Close-to-close realized volatility, annualized. Needs at least three
/// closes (two returns).
pub fn realized_vol_close(closes: &[f64]) -> Option<f64> {
    population_stdev(&log_returns(closes)).map(|s| s * TRADING_DAYS.sqrt())
}

/// Parkinson (1980) high-low estimator, annualized. Roughly five times as
/// efficient as close-to-close on the same window; ignores gaps, so it
/// understates vol on names that jump overnight.
pub fn realized_vol_parkinson(candles: &[Candle]) -> Option<f64> {
    if candles.is_empty() {
        return None;
    }
    let sum: f64 = candles
        .iter()
        .map(|c| (c.mid.high / c.mid.low).ln().powi(2))
        .sum();
    let var = sum / (4.0 * std::f64::consts::LN_2 * candles.len() as f64);
    Some((var * TRADING_DAYS).sqrt())
}

/// Garman-Klass (1980) OHLC estimator, annualized. Uses the open and close
/// as well as the range; still gap-blind.
pub fn realized_vol_garman_klass(candles: &[Candle]) -> Option<f64> {
    if candles.is_empty() {
        return None;
    }
    let k = 2.0 * std::f64::consts::LN_2 - 1.0;
    let sum: f64 = candles
        .iter()
        .map(|c| {
            0.5 * (c.mid.high / c.mid.low).ln().powi(2)
                - k * (c.mid.close / c.mid.open).ln().powi(2)
        })
        .sum();
    let var = (sum / candles.len() as f64).max(0.0);
    Some((var * TRADING_DAYS).sqrt())
}

/// Where `current` sits between the min and max of `history`, 0..=1.
/// None when the history is empty or flat.
pub fn iv_rank(current: f64, history: &[f64]) -> Option<f64> {
    let lo = history.iter().copied().fold(f64::INFINITY, f64::min);
    let hi = history.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    if history.is_empty() || hi <= lo {
        return None;
    }
    Some(((current - lo) / (hi - lo)).clamp(0.0, 1.0))
}

/// Fraction of `history` strictly below `current`, 0..=1. Less sensitive
/// to a single spike than [`iv_rank`].
pub fn iv_percentile(current: f64, history: &[f64]) -> Option<f64> {
    if history.is_empty() {
        return None;
    }
    let below = history.iter().filter(|h| **h < current).count();
    Some(below as f64 / history.len() as f64)
}

/// One-standard-deviation move the market prices over `t` years:
/// `spot × sigma × sqrt(t)`.
pub fn expected_move(spot: f64, sigma: f64, t: f64) -> f64 {
    spot * sigma * t.max(0.0).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::{Duration, TimeZone, Utc};

    fn candle(i: i64, o: f64, h: f64, l: f64, c: f64) -> Candle {
        Candle::from_trade_bar(
            Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap() + Duration::days(i),
            OHLC {
                open: o,
                high: h,
                low: l,
                close: c,
            },
            1.0,
        )
    }

    #[test]
    fn close_to_close_matches_a_hand_calculation() {
        // Returns: ln(1.01), ln(0.99/1.01), ln(1.02/0.99)
        let closes = [100.0, 101.0, 99.0, 102.0];
        let r = log_returns(&closes);
        assert_eq!(r.len(), 3);
        let mean = r.iter().sum::<f64>() / 3.0;
        let var = r.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / 3.0;
        let expected = var.sqrt() * 252f64.sqrt();
        assert!((realized_vol_close(&closes).unwrap() - expected).abs() < 1e-12);
        assert!(realized_vol_close(&[100.0, 101.0]).is_none());
        assert_eq!(realized_vol_close(&[100.0, 100.0, 100.0]).unwrap(), 0.0);
    }

    #[test]
    fn range_estimators_agree_on_a_constant_range_and_vanish_on_flat_bars() {
        // Each day: open=close=100, high/low = 100·e^{±0.01}: ln(H/L) = 0.02.
        let (h, l) = (100.0 * 0.01f64.exp(), 100.0 * (-0.01f64).exp());
        let bars: Vec<Candle> = (0..20).map(|i| candle(i, 100.0, h, l, 100.0)).collect();
        let park = realized_vol_parkinson(&bars).unwrap();
        let expected = (0.02f64.powi(2) / (4.0 * std::f64::consts::LN_2) * 252.0).sqrt();
        assert!((park - expected).abs() < 1e-12);
        // With open == close the Garman-Klass close term vanishes: 0.5·ln(H/L)².
        let gk = realized_vol_garman_klass(&bars).unwrap();
        assert!((gk - (0.5 * 0.02f64.powi(2) * 252.0).sqrt()).abs() < 1e-12);

        let flat: Vec<Candle> = (0..5)
            .map(|i| candle(i, 100.0, 100.0, 100.0, 100.0))
            .collect();
        assert_eq!(realized_vol_parkinson(&flat).unwrap(), 0.0);
        assert_eq!(realized_vol_garman_klass(&flat).unwrap(), 0.0);
        assert!(realized_vol_parkinson(&[]).is_none());
    }

    #[test]
    fn iv_rank_and_percentile_behave_at_the_edges() {
        let hist = [0.10, 0.20, 0.30, 0.40, 0.50];
        assert!((iv_rank(0.30, &hist).unwrap() - 0.5).abs() < 1e-12);
        assert_eq!(iv_rank(0.90, &hist), Some(1.0));
        assert_eq!(iv_rank(0.05, &hist), Some(0.0));
        assert!(iv_rank(0.3, &[0.2, 0.2]).is_none());
        assert!(iv_rank(0.3, &[]).is_none());
        assert_eq!(iv_percentile(0.35, &hist), Some(0.6));
        assert_eq!(iv_percentile(0.10, &hist), Some(0.0));
        assert!(iv_percentile(0.1, &[]).is_none());
    }

    #[test]
    fn expected_move_scales_with_root_time() {
        assert!((expected_move(650.0, 0.20, 0.25) - 65.0).abs() < 1e-12);
        assert_eq!(expected_move(650.0, 0.20, -1.0), 0.0);
    }
}
