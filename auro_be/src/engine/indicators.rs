use crate::engine::types::{BollingerBands, Candle};

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
        let high = candles[i].high;
        let low = candles[i].low;
        let prev_high = candles[i - 1].high;
        let prev_low = candles[i - 1].low;
        let prev_close = candles[i - 1].close;

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

    for i in period..trs.len() {
        s_tr = s_tr - s_tr / p_f + trs[i];
        s_plus = s_plus - s_plus / p_f + plus_dms[i];
        s_minus = s_minus - s_minus / p_f + minus_dms[i];
        dxs.push(dx_value(s_plus, s_minus, s_tr));
    }

    if dxs.len() < period {
        return None;
    }

    // Wilder-smooth DX into ADX: first = simple mean of first `period`, then prev * (p-1)/p + curr/p
    let mut adx: f64 = dxs[..period].iter().sum::<f64>() / p_f;
    for i in period..dxs.len() {
        adx = (adx * (p_f - 1.0) + dxs[i]) / p_f;
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

/// Average True Range over `period` bars, expressed as a percentage of the most recent close.
/// Returns None if there are fewer than `period + 1` candles.
pub fn atr_pct(candles: &[Candle], period: usize) -> Option<f64> {
    if period == 0 || candles.len() < period + 1 {
        return None;
    }

    let trs: Vec<f64> = (1..candles.len())
        .map(|i| {
            let high = candles[i].high;
            let low = candles[i].low;
            let prev_close = candles[i - 1].close;
            (high - low)
                .max((high - prev_close).abs())
                .max((low - prev_close).abs())
        })
        .collect();

    let p_f = period as f64;
    let mut atr: f64 = trs[..period].iter().sum::<f64>() / p_f;
    for i in period..trs.len() {
        atr = (atr * (p_f - 1.0) + trs[i]) / p_f;
    }

    let last_close = candles.last()?.close;
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
    let middle: f64 = window.iter().map(|c| c.close).sum::<f64>() / p_f;
    let variance: f64 = window
        .iter()
        .map(|c| {
            let diff = c.close - middle;
            diff * diff
        })
        .sum::<f64>()
        / p_f;
    let std_dev = variance.sqrt();

    let upper = middle + std_dev_mult * std_dev;
    let lower = middle - std_dev_mult * std_dev;
    let last_close = candles.last()?.close;

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

/// Percentage deviation of the most recent close from the `period`-bar SMA.
/// Positive = price above MA, negative = below. Returns None if fewer than `period` candles.
pub fn ma_deviation_pct(candles: &[Candle], period: usize) -> Option<f64> {
    if period == 0 || candles.len() < period {
        return None;
    }

    let window = &candles[candles.len() - period..];
    let ma: f64 = window.iter().map(|c| c.close).sum::<f64>() / period as f64;
    if ma <= 0.0 {
        return None;
    }

    let last_close = candles.last()?.close;
    Some((last_close - ma) / ma * 100.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, TimeZone, Utc};

    fn ohlc(open: f64, high: f64, low: f64, close: f64, idx: i64) -> Candle {
        Candle {
            time: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap() + Duration::hours(idx),
            open,
            high,
            low,
            close,
            volume: 1,
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
    fn atr_pct_basic_calculation() {
        // Each bar has high=100.5, low=99.5, close=100. TR=1.0 every bar (high-low dominates).
        // ATR = 1.0; close = 100; ATR% = 1.0
        let candles: Vec<Candle> = (0..20).map(|i| ohlc(100.0, 100.5, 99.5, 100.0, i)).collect();

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
        let mut candles: Vec<Candle> =
            (0..19).map(|i| flat(100.0 + 0.1 * (i as f64 % 2.0 - 0.5), i)).collect();
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
}
