//! Indicator math primitives.
//!
//! # Conventions (freeze — do not change without recalibrating thresholds)
//!
//! - **Rolling stdev is population (divide by n), not sample (n-1).** Matches
//!   the Investopedia MR baseline and standard TA convention (Bollinger,
//!   rolling Z, ATR). Switching to sample stdev would shift every Z-threshold
//!   ever calibrated.
//! - **RSI uses Wilder smoothing** (not simple MA). Flat series (avg_gain ==
//!   avg_loss == 0) returns the neutral 50, not the asymmetric 100. Only-gain
//!   series returns 100; only-loss series returns 0.
//! - **All rolling windows reference `candles[candles.len() - period..]`** —
//!   the most recent `period` bars including the latest closed bar.
//!
//! Comparator strictness conventions live next to the signal logic they
//! govern (see `mean_reversion.rs` and `trend_following.rs`).

use crate::engine::types::{BollingerBands, Candle};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MacdOutput {
    pub macd_line: f64,
    pub signal_line: f64,
    pub histogram: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DonchianChannel {
    pub upper: f64,
    pub lower: f64,
    pub mid: f64,
}

/// Window-seeded EMA over candle closes.
///
/// Seeds with the SMA of the first `period` closes, then applies the
/// standard smoothing factor k = 2 / (period + 1). With adequate history
/// (roughly 3x period or more), this converges close to fully historical EMA.
pub fn ema(candles: &[Candle], period: usize) -> Option<f64> {
    if period == 0 || candles.len() < period {
        return None;
    }

    let mut ema_value = candles[..period].iter().map(|c| c.mid.close).sum::<f64>() / period as f64;
    let k = 2.0 / (period as f64 + 1.0);

    for candle in candles.iter().skip(period) {
        ema_value = candle.mid.close * k + ema_value * (1.0 - k);
    }

    Some(ema_value)
}

fn ema_values(values: &[f64], period: usize) -> Option<f64> {
    if period == 0 || values.len() < period {
        return None;
    }

    let mut ema_value = values[..period].iter().sum::<f64>() / period as f64;
    let k = 2.0 / (period as f64 + 1.0);

    for value in values.iter().skip(period) {
        ema_value = value * k + ema_value * (1.0 - k);
    }

    Some(ema_value)
}

/// MACD over the candle window using window-seeded EMAs.
///
/// Returns None when periods are invalid (`fast >= slow`, zero periods) or
/// when there are fewer than `slow + signal` candles to build the MACD series
/// and then smooth it with the signal EMA.
pub fn macd(candles: &[Candle], fast: usize, slow: usize, signal: usize) -> Option<MacdOutput> {
    if fast == 0 || slow == 0 || signal == 0 || fast >= slow {
        return None;
    }
    if candles.len() < slow + signal {
        return None;
    }

    let mut macd_series: Vec<f64> = Vec::with_capacity(candles.len() - slow + 1);
    for end_exclusive in slow..=candles.len() {
        let window = &candles[..end_exclusive];
        let fast_ema = ema(window, fast)?;
        let slow_ema = ema(window, slow)?;
        macd_series.push(fast_ema - slow_ema);
    }

    let macd_line = *macd_series.last()?;
    let signal_line = ema_values(&macd_series, signal)?;

    Some(MacdOutput {
        macd_line,
        signal_line,
        histogram: macd_line - signal_line,
    })
}

/// Donchian channel over `period` prior bars, excluding the current bar.
///
/// Returns None when `period == 0` or when there are fewer than `period + 1`
/// candles (we need one current bar plus `period` history bars).
pub fn donchian(candles: &[Candle], period: usize) -> Option<DonchianChannel> {
    if period == 0 || candles.len() < period + 1 {
        return None;
    }

    let n = candles.len();
    let lookback = &candles[n - 1 - period..n - 1];

    let upper = lookback
        .iter()
        .map(|c| c.mid.high)
        .fold(f64::NEG_INFINITY, f64::max);
    let lower = lookback
        .iter()
        .map(|c| c.mid.low)
        .fold(f64::INFINITY, f64::min);

    Some(DonchianChannel {
        upper,
        lower,
        mid: (upper + lower) / 2.0,
    })
}

/// Average Directional Index over `period` bars.
/// Returns None if there are fewer than `period * 2` candles
/// (ADX needs warm-up for both the smoothed +DI/-DI and the smoothed DX).
pub fn adx(candles: &[Candle], period: usize) -> Option<f64> {
    if period == 0 || candles.len() < period * 2 {
        return None;
    }

    let n = candles.len();
    let mut trs: Vec<f64> = Vec::with_capacity(n - 1);
    let mut plus_dms: Vec<f64> = Vec::with_capacity(n - 1);
    let mut minus_dms: Vec<f64> = Vec::with_capacity(n - 1);

    for i in 1..n {
        let high = candles[i].mid.high;
        let low = candles[i].mid.low;
        let prev_high = candles[i - 1].mid.high;
        let prev_low = candles[i - 1].mid.low;
        let prev_close = candles[i - 1].mid.close;

        let tr = (high - low)
            .max((high - prev_close).abs())
            .max((low - prev_close).abs());

        let up_move = high - prev_high;
        let down_move = prev_low - low;

        let plus_dm = if up_move > down_move && up_move > 0.0 {
            up_move
        } else {
            0.0
        };
        let minus_dm = if down_move > up_move && down_move > 0.0 {
            down_move
        } else {
            0.0
        };

        trs.push(tr);
        plus_dms.push(plus_dm);
        minus_dms.push(minus_dm);
    }

    // Wilder smoothing: first = sum of first `period`, then prev - prev/period + current
    let p_f = period as f64;
    let mut s_tr: f64 = trs[..period].iter().sum();
    let mut s_plus: f64 = plus_dms[..period].iter().sum();
    let mut s_minus: f64 = minus_dms[..period].iter().sum();

    let mut dxs: Vec<f64> = Vec::with_capacity(trs.len() - period + 1);
    dxs.push(dx_value(s_plus, s_minus, s_tr));

    for ((tr, plus_dm), minus_dm) in trs
        .iter()
        .skip(period)
        .zip(plus_dms.iter().skip(period))
        .zip(minus_dms.iter().skip(period))
    {
        s_tr = s_tr - s_tr / p_f + *tr;
        s_plus = s_plus - s_plus / p_f + *plus_dm;
        s_minus = s_minus - s_minus / p_f + *minus_dm;
        dxs.push(dx_value(s_plus, s_minus, s_tr));
    }

    if dxs.len() < period {
        return None;
    }

    // Wilder-smooth DX into ADX: first = simple mean of first `period`, then prev * (p-1)/p + curr/p
    let mut adx: f64 = dxs[..period].iter().sum::<f64>() / p_f;
    for dx in dxs.iter().skip(period) {
        adx = (adx * (p_f - 1.0) + *dx) / p_f;
    }

    Some(adx)
}

fn dx_value(s_plus: f64, s_minus: f64, s_tr: f64) -> f64 {
    if s_tr <= 0.0 {
        return 0.0;
    }
    let plus_di = 100.0 * s_plus / s_tr;
    let minus_di = 100.0 * s_minus / s_tr;
    let di_sum = plus_di + minus_di;
    if di_sum <= 0.0 {
        return 0.0;
    }
    100.0 * (plus_di - minus_di).abs() / di_sum
}

/// Average True Range over `period` bars in absolute price units.
/// Uses Wilder smoothing and returns None if there are fewer than
/// `period + 1` candles.
pub fn atr(candles: &[Candle], period: usize) -> Option<f64> {
    if period == 0 || candles.len() < period + 1 {
        return None;
    }

    let trs: Vec<f64> = (1..candles.len())
        .map(|i| {
            let high = candles[i].mid.high;
            let low = candles[i].mid.low;
            let prev_close = candles[i - 1].mid.close;
            (high - low)
                .max((high - prev_close).abs())
                .max((low - prev_close).abs())
        })
        .collect();

    let p_f = period as f64;
    let mut atr: f64 = trs[..period].iter().sum::<f64>() / p_f;
    for tr in trs.iter().skip(period) {
        atr = (atr * (p_f - 1.0) + *tr) / p_f;
    }

    Some(atr)
}

/// Average True Range over `period` bars, expressed as a percentage of the most recent close.
/// Returns None if there are fewer than `period + 1` candles.
pub fn atr_pct(candles: &[Candle], period: usize) -> Option<f64> {
    let atr = atr(candles, period)?;
    let last_close = candles.last()?.mid.close;
    if last_close <= 0.0 {
        return None;
    }

    Some(atr / last_close * 100.0)
}

/// Bollinger Bands using `period` SMA and `std_dev_mult` standard deviations.
/// Returns None if there are fewer than `period` candles.
/// Uses population standard deviation (divide by N), per Bollinger's original spec.
pub fn bollinger(candles: &[Candle], period: usize, std_dev_mult: f64) -> Option<BollingerBands> {
    if period == 0 || candles.len() < period {
        return None;
    }

    let window = &candles[candles.len() - period..];
    let p_f = period as f64;
    let middle: f64 = window.iter().map(|c| c.mid.close).sum::<f64>() / p_f;
    let variance: f64 = window
        .iter()
        .map(|c| {
            let diff = c.mid.close - middle;
            diff * diff
        })
        .sum::<f64>()
        / p_f;
    let std_dev = variance.sqrt();

    let upper = middle + std_dev_mult * std_dev;
    let lower = middle - std_dev_mult * std_dev;
    let last_close = candles.last()?.mid.close;

    let bandwidth_pct = if middle != 0.0 {
        (upper - lower) / middle * 100.0
    } else {
        0.0
    };
    let position = if upper > lower {
        (last_close - lower) / (upper - lower)
    } else {
        0.5
    };

    Some(BollingerBands {
        upper,
        middle,
        lower,
        bandwidth_pct,
        position,
    })
}

/// Rolling Z-score of the most recent close relative to a `period`-bar SMA and
/// population standard deviation. Per the Investopedia MR baseline:
///   Z = (price - mean) / stdev
/// Returns None if fewer than `period` candles or stdev is zero.
pub fn z_score(candles: &[Candle], period: usize) -> Option<f64> {
    if period == 0 || candles.len() < period {
        return None;
    }

    let window = &candles[candles.len() - period..];
    let p_f = period as f64;
    let mean: f64 = window.iter().map(|c| c.mid.close).sum::<f64>() / p_f;
    let variance: f64 = window
        .iter()
        .map(|c| {
            let diff = c.mid.close - mean;
            diff * diff
        })
        .sum::<f64>()
        / p_f;
    let std_dev = variance.sqrt();
    if std_dev <= 0.0 {
        return None;
    }
    let last_close = candles.last()?.mid.close;
    Some((last_close - mean) / std_dev)
}

/// Wilder's Relative Strength Index over `period` bars.
/// Returns a value in [0, 100], or None if fewer than `period + 1` candles.
pub fn rsi(candles: &[Candle], period: usize) -> Option<f64> {
    if period == 0 || candles.len() < period + 1 {
        return None;
    }

    let p_f = period as f64;

    // First gains/losses from candle deltas
    let mut gains: Vec<f64> = Vec::with_capacity(candles.len() - 1);
    let mut losses: Vec<f64> = Vec::with_capacity(candles.len() - 1);
    for i in 1..candles.len() {
        let delta = candles[i].mid.close - candles[i - 1].mid.close;
        if delta >= 0.0 {
            gains.push(delta);
            losses.push(0.0);
        } else {
            gains.push(0.0);
            losses.push(-delta);
        }
    }

    // Wilder smoothing: first avg = simple mean of first `period`,
    // then avg = (prev * (period - 1) + current) / period
    let mut avg_gain: f64 = gains[..period].iter().sum::<f64>() / p_f;
    let mut avg_loss: f64 = losses[..period].iter().sum::<f64>() / p_f;

    for i in period..gains.len() {
        avg_gain = (avg_gain * (p_f - 1.0) + gains[i]) / p_f;
        avg_loss = (avg_loss * (p_f - 1.0) + losses[i]) / p_f;
    }

    // Flat series (no movement either direction) → neutral 50, not 100.
    // Only-gain (avg_loss == 0, avg_gain > 0) → 100. Only-loss falls through
    // and resolves to 0 via the standard formula.
    if avg_gain == 0.0 && avg_loss == 0.0 {
        return Some(50.0);
    }
    if avg_loss == 0.0 {
        return Some(100.0);
    }
    let rs = avg_gain / avg_loss;
    Some(100.0 - (100.0 / (1.0 + rs)))
}

/// Percentage deviation of the most recent close from the `period`-bar SMA.
/// Positive = price above MA, negative = below. Returns None if fewer than `period` candles.
pub fn ma_deviation_pct(candles: &[Candle], period: usize) -> Option<f64> {
    if period == 0 || candles.len() < period {
        return None;
    }

    let window = &candles[candles.len() - period..];
    let ma: f64 = window.iter().map(|c| c.mid.close).sum::<f64>() / period as f64;
    if ma <= 0.0 {
        return None;
    }

    let last_close = candles.last()?.mid.close;
    Some((last_close - ma) / ma * 100.0)
}

/// Volume-Weighted Average Price over the supplied candle slice.
///
/// VWAP = Σ(typical_price × volume) / Σ(volume)
/// typical_price = (high + low + close) / 3
///
/// The caller controls the anchor by passing the right slice (e.g. candles
/// from session open to now). Returns None if there are no candles or total
/// volume is zero (tick volume proxies are always > 0 on real data, but we
/// guard for safety).
pub fn vwap(candles: &[Candle]) -> Option<f64> {
    if candles.is_empty() {
        return None;
    }
    let (tp_vol, vol): (f64, f64) = candles.iter().fold((0.0, 0.0), |(tv, v), c| {
        let tp = (c.mid.high + c.mid.low + c.mid.close) / 3.0;
        let vol = c.volume as f64;
        (tv + tp * vol, v + vol)
    });
    if vol <= 0.0 {
        return None;
    }
    Some(tp_vol / vol)
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OpeningRange {
    pub high: f64,
    pub low: f64,
}

/// High and low of the first `bars` candles in the slice.
///
/// Used for opening-range breakout and support/resistance reference.
/// Returns None if `bars == 0` or the slice has fewer than `bars` candles.
pub fn opening_range(candles: &[Candle], bars: usize) -> Option<OpeningRange> {
    if bars == 0 || candles.len() < bars {
        return None;
    }
    let window = &candles[..bars];
    let high = window
        .iter()
        .map(|c| c.mid.high)
        .fold(f64::NEG_INFINITY, f64::max);
    let low = window
        .iter()
        .map(|c| c.mid.low)
        .fold(f64::INFINITY, f64::min);
    Some(OpeningRange { high, low })
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StochasticOutput {
    /// Raw stochastic: position of close within the period's high-low range, 0–100.
    pub k: f64,
    /// Signal line: `signal_period`-bar SMA of %K.
    pub d: f64,
}

/// Fast Stochastic Oscillator (%K and %D).
///
/// %K = (close - lowest_low) / (highest_high - lowest_low) × 100
/// %D = `signal_period`-bar SMA of %K values
///
/// Returns None when `period == 0`, `signal_period == 0`, or the slice has
/// fewer than `period + signal_period - 1` candles (need enough %K values to
/// smooth into %D).
pub fn stochastic(
    candles: &[Candle],
    period: usize,
    signal_period: usize,
) -> Option<StochasticOutput> {
    if period == 0 || signal_period == 0 || candles.len() < period + signal_period - 1 {
        return None;
    }

    // Build the full %K series over the available window.
    let k_series: Vec<f64> = (period - 1..candles.len())
        .map(|end| {
            let window = &candles[end + 1 - period..=end];
            let highest = window
                .iter()
                .map(|c| c.mid.high)
                .fold(f64::NEG_INFINITY, f64::max);
            let lowest = window
                .iter()
                .map(|c| c.mid.low)
                .fold(f64::INFINITY, f64::min);
            let close = candles[end].mid.close;
            if (highest - lowest).abs() < f64::EPSILON {
                50.0 // range collapsed → neutral
            } else {
                (close - lowest) / (highest - lowest) * 100.0
            }
        })
        .collect();

    let k = *k_series.last()?;
    let d = k_series[k_series.len() - signal_period..]
        .iter()
        .sum::<f64>()
        / signal_period as f64;

    Some(StochasticOutput { k, d })
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PivotPoints {
    pub pp: f64,
    pub r1: f64,
    pub s1: f64,
    pub r2: f64,
    pub s2: f64,
    pub r3: f64,
    pub s3: f64,
}

/// Classic (floor-trader) pivot points from the *previous* session's OHLC.
///
/// PP = (H + L + C) / 3
/// R1 = 2·PP − L,   S1 = 2·PP − H
/// R2 = PP + (H−L), S2 = PP − (H−L)
/// R3 = H + 2·(PP−L), S3 = L − 2·(H−PP)
///
/// Takes scalar inputs — the caller extracts the previous session's high/low/close
/// from its own candle slice. Pure function, no slice dependency.
pub fn pivot_points(prev_high: f64, prev_low: f64, prev_close: f64) -> PivotPoints {
    let pp = (prev_high + prev_low + prev_close) / 3.0;
    let range = prev_high - prev_low;
    PivotPoints {
        pp,
        r1: 2.0 * pp - prev_low,
        s1: 2.0 * pp - prev_high,
        r2: pp + range,
        s2: pp - range,
        r3: prev_high + 2.0 * (pp - prev_low),
        s3: prev_low - 2.0 * (prev_high - pp),
    }
}

/// Rate of Change over `period` bars, as a percentage.
///
/// ROC = (close − close[period bars ago]) / close[period bars ago] × 100
///
/// Returns None if `period == 0`, the slice has fewer than `period + 1`
/// candles, or the reference close is zero.
pub fn rate_of_change(candles: &[Candle], period: usize) -> Option<f64> {
    if period == 0 || candles.len() < period + 1 {
        return None;
    }
    let n = candles.len();
    let current = candles[n - 1].mid.close;
    let reference = candles[n - 1 - period].mid.close;
    if reference == 0.0 {
        return None;
    }
    Some((current - reference) / reference * 100.0)
}

#[cfg(test)]
mod tests {
    use crate::engine::types::OHLC;

    use super::*;
    use chrono::{Duration, TimeZone, Utc};

    fn ohlc(open: f64, high: f64, low: f64, close: f64, idx: i64) -> Candle {
        Candle {
            time: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap() + Duration::hours(idx),
            mid: OHLC {
                open,
                high,
                low,
                close,
            },
            volume: 1,
            bid: None,
            ask: None,
        }
    }

    fn flat(price: f64, idx: i64) -> Candle {
        ohlc(price, price, price, price, idx)
    }

    // -- ADX --

    #[test]
    fn adx_returns_none_when_buffer_too_small() {
        let candles: Vec<Candle> = (0..27).map(|i| flat(100.0, i)).collect();
        assert_eq!(adx(&candles, 14), None);
    }

    #[test]
    fn adx_returns_none_for_zero_period() {
        let candles: Vec<Candle> = (0..50).map(|i| flat(100.0, i)).collect();
        assert_eq!(adx(&candles, 0), None);
    }

    #[test]
    fn adx_strong_uptrend_returns_high_value() {
        // Strict monotonic up: each high gaps above prev_high by 1.0, each low above prev_low by 1.0.
        // +DM = 1.0 every bar, -DM = 0 every bar -> DX = 100 every bar -> ADX = 100.
        let candles: Vec<Candle> = (0..50)
            .map(|i| {
                let base = 100.0 + i as f64;
                ohlc(base, base + 0.5, base - 0.2, base + 0.3, i)
            })
            .collect();

        let result = adx(&candles, 14).expect("ADX should compute with 50 candles");
        assert!(
            result > 25.0,
            "Expected ADX > 25 for strong uptrend, got {}",
            result
        );
    }

    #[test]
    fn adx_choppy_market_returns_low_value() {
        // Alternating bases — neither up nor down sustained. +DM and -DM cancel.
        let candles: Vec<Candle> = (0..50)
            .map(|i| {
                let base = if i % 2 == 0 { 100.0 } else { 99.5 };
                ohlc(base, base + 0.2, base - 0.2, base, i)
            })
            .collect();

        let result = adx(&candles, 14).expect("ADX should compute with 50 candles");
        assert!(
            result < 20.0,
            "Expected ADX < 20 for choppy market, got {}",
            result
        );
    }

    // -- ATR% --

    #[test]
    fn atr_pct_returns_none_with_insufficient_data() {
        let candles: Vec<Candle> = (0..14).map(|i| flat(100.0, i)).collect();
        assert_eq!(atr_pct(&candles, 14), None);
    }

    #[test]
    fn macd_returns_none_with_insufficient_data() {
        let candles: Vec<Candle> = (0..4).map(|i| flat((i + 1) as f64, i)).collect();
        assert_eq!(macd(&candles, 2, 3, 2), None);
    }

    #[test]
    fn macd_basic_calculation() {
        // Closes 1..6 with fast=2, slow=3, signal=2:
        // EMA2(last)=5.5, EMA3(last)=5.0 => MACD line=0.5.
        // MACD series is constant [0.5, 0.5, 0.5, 0.5], so signal=0.5,
        // histogram=0.0.
        let candles: Vec<Candle> = (1..=6)
            .enumerate()
            .map(|(i, p)| flat(p as f64, i as i64))
            .collect();

        let out = macd(&candles, 2, 3, 2).expect("MACD should compute");
        assert!((out.macd_line - 0.5).abs() < 1e-9, "macd={}", out.macd_line);
        assert!(
            (out.signal_line - 0.5).abs() < 1e-9,
            "signal={}",
            out.signal_line
        );
        assert!((out.histogram - 0.0).abs() < 1e-9, "hist={}", out.histogram);
    }

    #[test]
    fn donchian_returns_none_with_insufficient_data() {
        let candles: Vec<Candle> = (0..20).map(|i| flat(100.0, i)).collect();
        assert_eq!(donchian(&candles, 20), None);
    }

    #[test]
    fn donchian_uses_prior_period_excluding_current_bar() {
        let mut candles: Vec<Candle> = (0..20)
            .map(|i| {
                let high = 100.0 + i as f64;
                let low = 90.0 + i as f64;
                ohlc(95.0 + i as f64, high, low, 95.0 + i as f64, i)
            })
            .collect();

        // Current bar has an extreme high that must be excluded from channel calc.
        candles.push(ohlc(120.0, 130.0, 95.0, 110.0, 20));

        let channel = donchian(&candles, 20).expect("Donchian should compute");
        assert!(
            (channel.upper - 119.0).abs() < 1e-9,
            "upper={}",
            channel.upper
        );
        assert!(
            (channel.lower - 90.0).abs() < 1e-9,
            "lower={}",
            channel.lower
        );
        assert!((channel.mid - 104.5).abs() < 1e-9, "mid={}", channel.mid);
    }

    #[test]
    fn atr_basic_calculation_price_units() {
        // Deterministic TR sequence with period=3:
        // TR1=3.0, TR2=4.0, TR3=5.0 -> ATR=4.0.
        let candles = vec![
            ohlc(100.0, 100.0, 100.0, 100.0, 0),
            ohlc(100.0, 102.0, 99.0, 101.0, 1),
            ohlc(101.0, 101.0, 97.0, 98.0, 2),
            ohlc(98.0, 103.0, 100.0, 102.0, 3),
        ];

        let result = atr(&candles, 3).expect("ATR should compute with 4 candles");
        assert!(
            (result - 4.0).abs() < 1e-9,
            "Expected ATR=4.0, got {}",
            result
        );
    }

    #[test]
    fn atr_pct_basic_calculation() {
        // Each bar has high=100.5, low=99.5, close=100. TR=1.0 every bar (high-low dominates).
        // ATR = 1.0; close = 100; ATR% = 1.0
        let candles: Vec<Candle> = (0..20)
            .map(|i| ohlc(100.0, 100.5, 99.5, 100.0, i))
            .collect();

        let result = atr_pct(&candles, 14).expect("ATR should compute with 20 candles");
        assert!(
            (result - 1.0).abs() < 0.01,
            "Expected ATR%=1.0, got {}",
            result
        );
    }

    // -- Bollinger --

    #[test]
    fn bollinger_returns_none_with_insufficient_data() {
        let candles: Vec<Candle> = (0..19).map(|i| flat(100.0, i)).collect();
        assert!(bollinger(&candles, 20, 2.0).is_none());
    }

    #[test]
    fn bollinger_centered_price_position_is_half() {
        // 9 bars at 98, 9 bars at 102, 2 bars at 100 (last = 100).
        // Mean = 100, last_close = 100 -> position = 0.5
        let mut prices: Vec<f64> = Vec::with_capacity(20);
        for i in 0..18 {
            prices.push(if i % 2 == 0 { 98.0 } else { 102.0 });
        }
        prices.push(100.0);
        prices.push(100.0);

        let candles: Vec<Candle> = prices
            .into_iter()
            .enumerate()
            .map(|(i, p)| flat(p, i as i64))
            .collect();

        let bb = bollinger(&candles, 20, 2.0).expect("BB should compute with 20 candles");
        assert!((bb.middle - 100.0).abs() < 0.001);
        assert!(
            (bb.position - 0.5).abs() < 0.05,
            "Expected position ~0.5, got {}",
            bb.position
        );
        assert!(bb.bandwidth_pct > 0.0);
    }

    #[test]
    fn bollinger_at_upper_band_position_is_one() {
        // Most prices at 100, last price spikes high enough to sit at the upper band.
        let mut candles: Vec<Candle> = (0..19)
            .map(|i| flat(100.0 + 0.1 * (i as f64 % 2.0 - 0.5), i))
            .collect();
        // Upper band ≈ middle + 2*std_dev. Set last close to a value above all priors.
        candles.push(flat(101.0, 19));

        let bb = bollinger(&candles, 20, 2.0).expect("BB should compute");
        assert!(
            bb.position > 0.9,
            "Expected position near 1.0 at upper band, got {}",
            bb.position
        );
    }

    // -- MA deviation --

    #[test]
    fn ma_deviation_returns_none_with_insufficient_data() {
        let candles: Vec<Candle> = (0..19).map(|i| flat(100.0, i)).collect();
        assert!(ma_deviation_pct(&candles, 20).is_none());
    }

    #[test]
    fn ma_deviation_above_ma_returns_positive() {
        // 19 bars at 100, last bar at 105. MA = (19*100 + 105)/20 = 100.25
        // Deviation = (105 - 100.25)/100.25 * 100 ≈ 4.738%
        let mut candles: Vec<Candle> = (0..19).map(|i| flat(100.0, i)).collect();
        candles.push(flat(105.0, 19));

        let result = ma_deviation_pct(&candles, 20).unwrap();
        assert!(result > 0.0, "Expected positive deviation, got {}", result);
        assert!(
            (result - 4.738).abs() < 0.01,
            "Expected ~4.738%, got {}",
            result
        );
    }

    #[test]
    fn ma_deviation_below_ma_returns_negative() {
        let mut candles: Vec<Candle> = (0..19).map(|i| flat(100.0, i)).collect();
        candles.push(flat(95.0, 19));

        let result = ma_deviation_pct(&candles, 20).unwrap();
        assert!(result < 0.0, "Expected negative deviation, got {}", result);
    }

    #[test]
    fn ma_deviation_at_ma_returns_zero() {
        let candles: Vec<Candle> = (0..20).map(|i| flat(100.0, i)).collect();
        let result = ma_deviation_pct(&candles, 20).unwrap();
        assert!(
            result.abs() < 1e-9,
            "Expected ~0 when price equals MA, got {}",
            result
        );
    }

    // -- Z-score --

    #[test]
    fn z_score_returns_none_with_insufficient_data() {
        let candles: Vec<Candle> = (0..19).map(|i| flat(100.0, i)).collect();
        assert!(z_score(&candles, 20).is_none());
    }

    #[test]
    fn z_score_returns_none_when_stdev_is_zero() {
        // All identical prices → stdev = 0 → undefined Z
        let candles: Vec<Candle> = (0..20).map(|i| flat(100.0, i)).collect();
        assert!(z_score(&candles, 20).is_none());
    }

    #[test]
    fn z_score_positive_above_mean() {
        // 19 candles at 100, last at 110. mean = 100.5, stdev computed.
        // Z = (110 - 100.5) / stdev — magnitude > 0
        let mut candles: Vec<Candle> = (0..19).map(|i| flat(100.0, i)).collect();
        candles.push(flat(110.0, 19));
        let z = z_score(&candles, 20).expect("Z should compute with 20 candles");
        assert!(z > 0.0, "Expected positive Z above mean, got {}", z);
    }

    #[test]
    fn z_score_negative_below_mean() {
        let mut candles: Vec<Candle> = (0..19).map(|i| flat(100.0, i)).collect();
        candles.push(flat(90.0, 19));
        let z = z_score(&candles, 20).expect("Z should compute");
        assert!(z < 0.0, "Expected negative Z below mean, got {}", z);
    }

    #[test]
    fn z_score_matches_manual_calculation() {
        // Construct prices where mean and stdev are easy to compute manually.
        // Prices: nine 95s, ten 105s, last 100. mean = (9*95 + 10*105 + 100)/20 = 100.25
        let mut prices = vec![95.0; 9];
        prices.extend(vec![105.0; 10]);
        prices.push(100.0);
        let candles: Vec<Candle> = prices
            .into_iter()
            .enumerate()
            .map(|(i, p)| flat(p, i as i64))
            .collect();
        let z = z_score(&candles, 20).expect("Z should compute");
        // Verify Z magnitude is small (last close near mean)
        assert!(z.abs() < 0.1, "Expected small |Z| near mean, got {}", z);
    }

    // -- RSI --

    #[test]
    fn rsi_returns_none_with_insufficient_data() {
        let candles: Vec<Candle> = (0..14).map(|i| flat(100.0, i)).collect();
        assert!(rsi(&candles, 14).is_none());
    }

    #[test]
    fn rsi_all_gains_returns_100() {
        // Monotonically rising prices → only gains, no losses → RSI = 100
        let candles: Vec<Candle> = (0..30).map(|i| flat(100.0 + i as f64, i as i64)).collect();
        let r = rsi(&candles, 14).expect("RSI should compute");
        assert!((r - 100.0).abs() < 1e-9, "Expected RSI=100, got {}", r);
    }

    #[test]
    fn rsi_all_losses_returns_low_value() {
        // Monotonically falling prices → only losses → RSI = 0
        let candles: Vec<Candle> = (0..30).map(|i| flat(200.0 - i as f64, i as i64)).collect();
        let r = rsi(&candles, 14).expect("RSI should compute");
        assert!(
            r < 5.0,
            "Expected RSI near 0 for all-loss series, got {}",
            r
        );
    }

    #[test]
    fn rsi_flat_returns_50() {
        // Zero-delta series (avg_gain == avg_loss == 0) → neutral 50, not 100.
        let candles: Vec<Candle> = (0..30).map(|i| flat(100.0, i as i64)).collect();
        let r = rsi(&candles, 14).expect("RSI should compute on flat series");
        assert!(
            (r - 50.0).abs() < 1e-9,
            "Expected RSI=50 for flat series, got {}",
            r
        );
    }

    #[test]
    fn rsi_alternating_returns_mid_range() {
        // Alternating up/down of equal magnitude → avg gain ≈ avg loss → RSI ≈ 50
        let mut candles: Vec<Candle> = Vec::with_capacity(30);
        for i in 0..30 {
            let p = if i % 2 == 0 { 100.0 } else { 101.0 };
            candles.push(flat(p, i as i64));
        }
        let r = rsi(&candles, 14).expect("RSI should compute");
        assert!(
            (r - 50.0).abs() < 5.0,
            "Expected RSI ~50 for alternating series, got {}",
            r
        );
    }

    // -- VWAP --

    #[test]
    fn vwap_returns_none_on_empty_slice() {
        assert!(vwap(&[]).is_none());
    }

    #[test]
    fn vwap_single_candle_equals_typical_price() {
        // TP = (110 + 90 + 100) / 3 = 100.0; volume = 1 → VWAP = 100.0
        let c = ohlc(100.0, 110.0, 90.0, 100.0, 0);
        let result = vwap(&[c]).expect("VWAP should compute");
        assert!((result - 100.0).abs() < 1e-9, "vwap={}", result);
    }

    #[test]
    fn vwap_equal_volume_equals_mean_of_typical_prices() {
        // All candles have volume=1; VWAP = arithmetic mean of TPs.
        // TP1 = (120+80+100)/3 = 100.0, TP2 = (130+90+110)/3 = 110.0 → mean = 105.0
        let candles = vec![
            ohlc(100.0, 120.0, 80.0, 100.0, 0),
            ohlc(110.0, 130.0, 90.0, 110.0, 1),
        ];
        let result = vwap(&candles).expect("VWAP should compute");
        assert!((result - 105.0).abs() < 1e-9, "vwap={}", result);
    }

    #[test]
    fn vwap_higher_volume_bar_pulls_result_toward_its_typical_price() {
        // Bar 0: TP=100, vol=1. Bar 1: TP=200, vol=9.
        // VWAP = (100*1 + 200*9) / 10 = 190.0
        let candles = vec![
            Candle {
                time: flat(100.0, 0).time,
                mid: OHLC {
                    open: 100.0,
                    high: 100.0,
                    low: 100.0,
                    close: 100.0,
                },
                volume: 1,
                bid: None,
                ask: None,
            },
            Candle {
                time: flat(200.0, 1).time,
                mid: OHLC {
                    open: 200.0,
                    high: 200.0,
                    low: 200.0,
                    close: 200.0,
                },
                volume: 9,
                bid: None,
                ask: None,
            },
        ];
        let result = vwap(&candles).expect("VWAP should compute");
        assert!((result - 190.0).abs() < 1e-9, "vwap={}", result);
    }

    // -- Opening range --

    #[test]
    fn opening_range_returns_none_when_bars_is_zero() {
        let candles: Vec<Candle> = (0..5).map(|i| flat(100.0, i)).collect();
        assert!(opening_range(&candles, 0).is_none());
    }

    #[test]
    fn opening_range_returns_none_when_insufficient_candles() {
        let candles: Vec<Candle> = (0..3).map(|i| flat(100.0, i)).collect();
        assert!(opening_range(&candles, 5).is_none());
    }

    #[test]
    fn opening_range_uses_only_first_n_bars() {
        // First 3 bars: highs 101, 103, 102; lows 99, 98, 97 → range high=103, low=97.
        // Bar 4 has an extreme that must be excluded.
        let candles = vec![
            ohlc(100.0, 101.0, 99.0, 100.0, 0),
            ohlc(100.0, 103.0, 98.0, 101.0, 1),
            ohlc(101.0, 102.0, 97.0, 100.0, 2),
            ohlc(100.0, 120.0, 80.0, 100.0, 3), // excluded
        ];
        let or = opening_range(&candles, 3).expect("OR should compute");
        assert!((or.high - 103.0).abs() < 1e-9, "high={}", or.high);
        assert!((or.low - 97.0).abs() < 1e-9, "low={}", or.low);
    }

    // -- Stochastic --

    #[test]
    fn stochastic_returns_none_when_insufficient_data() {
        let candles: Vec<Candle> = (0..5).map(|i| flat(100.0, i)).collect();
        // period=14, signal=3 needs 16 candles
        assert!(stochastic(&candles, 14, 3).is_none());
    }

    #[test]
    fn stochastic_returns_none_for_zero_period() {
        let candles: Vec<Candle> = (0..20).map(|i| flat(100.0, i)).collect();
        assert!(stochastic(&candles, 0, 3).is_none());
    }

    #[test]
    fn stochastic_close_at_high_returns_100() {
        // Close equals high equals 110, low is 90 for all bars. %K = 100.
        let candles: Vec<Candle> = (0..20)
            .map(|i| ohlc(110.0, 110.0, 90.0, 110.0, i))
            .collect();
        let out = stochastic(&candles, 14, 3).expect("Stochastic should compute");
        assert!((out.k - 100.0).abs() < 1e-9, "k={}", out.k);
        assert!((out.d - 100.0).abs() < 1e-9, "d={}", out.d);
    }

    #[test]
    fn stochastic_close_at_low_returns_0() {
        // Close equals low equals 90, high is 110 for all bars. %K = 0.
        let candles: Vec<Candle> = (0..20).map(|i| ohlc(90.0, 110.0, 90.0, 90.0, i)).collect();
        let out = stochastic(&candles, 14, 3).expect("Stochastic should compute");
        assert!((out.k - 0.0).abs() < 1e-9, "k={}", out.k);
    }

    #[test]
    fn stochastic_collapsed_range_returns_neutral_50() {
        // All bars identical → range = 0 → guard returns 50.
        let candles: Vec<Candle> = (0..20).map(|i| flat(100.0, i)).collect();
        let out = stochastic(&candles, 14, 3).expect("Stochastic should compute");
        assert!((out.k - 50.0).abs() < 1e-9, "k={}", out.k);
    }

    // -- Pivot points --

    #[test]
    fn pivot_points_textbook_values() {
        // H=1250, L=1200, C=1220 → PP = 1223.33…
        // R1 = 2*PP - L = 1246.67, S1 = 2*PP - H = 1196.67
        // R2 = PP + (H-L) = 1273.33, S2 = PP - (H-L) = 1173.33
        let pp_val = (1250.0 + 1200.0 + 1220.0) / 3.0;
        let pivots = pivot_points(1250.0, 1200.0, 1220.0);
        assert!((pivots.pp - pp_val).abs() < 1e-6, "pp={}", pivots.pp);
        assert!(
            (pivots.r1 - (2.0 * pp_val - 1200.0)).abs() < 1e-6,
            "r1={}",
            pivots.r1
        );
        assert!(
            (pivots.s1 - (2.0 * pp_val - 1250.0)).abs() < 1e-6,
            "s1={}",
            pivots.s1
        );
        assert!(
            (pivots.r2 - (pp_val + 50.0)).abs() < 1e-6,
            "r2={}",
            pivots.r2
        );
        assert!(
            (pivots.s2 - (pp_val - 50.0)).abs() < 1e-6,
            "s2={}",
            pivots.s2
        );
    }

    #[test]
    fn pivot_points_r_levels_above_pp_s_levels_below() {
        let p = pivot_points(110.0, 90.0, 100.0);
        assert!(p.r1 > p.pp && p.r2 > p.r1 && p.r3 > p.r2);
        assert!(p.s1 < p.pp && p.s2 < p.s1 && p.s3 < p.s2);
    }

    // -- Rate of change --

    #[test]
    fn rate_of_change_returns_none_with_insufficient_data() {
        let candles: Vec<Candle> = (0..5).map(|i| flat(100.0, i)).collect();
        assert!(rate_of_change(&candles, 5).is_none());
    }

    #[test]
    fn rate_of_change_returns_none_for_zero_period() {
        let candles: Vec<Candle> = (0..10).map(|i| flat(100.0, i)).collect();
        assert!(rate_of_change(&candles, 0).is_none());
    }

    #[test]
    fn rate_of_change_10_pct_gain() {
        // price 10 bars ago = 100, now = 110 → ROC = 10.0%
        let mut candles: Vec<Candle> = (0..10).map(|i| flat(100.0, i)).collect();
        candles.push(flat(110.0, 10));
        let roc = rate_of_change(&candles, 10).expect("ROC should compute");
        assert!((roc - 10.0).abs() < 1e-9, "roc={}", roc);
    }

    #[test]
    fn rate_of_change_decline_returns_negative() {
        let mut candles: Vec<Candle> = (0..10).map(|i| flat(100.0, i)).collect();
        candles.push(flat(90.0, 10));
        let roc = rate_of_change(&candles, 10).expect("ROC should compute");
        assert!(roc < 0.0, "roc={}", roc);
        assert!((roc - (-10.0)).abs() < 1e-9, "roc={}", roc);
    }

    #[test]
    fn rate_of_change_flat_series_returns_zero() {
        let candles: Vec<Candle> = (0..11).map(|i| flat(100.0, i)).collect();
        let roc = rate_of_change(&candles, 10).expect("ROC should compute");
        assert!(roc.abs() < 1e-9, "roc={}", roc);
    }
}
