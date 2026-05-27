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

/// Average True Range over `period` bars, expressed as a percentage of the most recent close.
/// Returns None if there are fewer than `period + 1` candles.
pub fn atr_pct(candles: &[Candle], period: usize) -> Option<f64> {
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
}
