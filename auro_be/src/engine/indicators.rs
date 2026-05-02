use crate::engine::types::{BollingerBands, Candle};


/// Average Directional Index over `period` bars.
/// Returns None if there are fewer than `period * 2` candles
/// (ADX needs warm-up for both the smoothed +DI/-DI and the smoothed DX).
pub fn adx(candles: &[Candle], period: usize) -> Option<f64>{ todo!() }

/// Average True Range over `period` bars, expressed as a percentage of the most recent close.
/// Returns None if there are fewer than `period + 1` candles.
pub fn atr_pct(candles: &[Candle], period: usize) -> Option<f64> { todo!() }

/// Bollinger Bands using `period` SMA and `std_dev_mult` standard deviations.
/// Returns None if there are fewer than `period` candles.
pub fn bollinger(candles: &[Candle], period: usize, std_dev_mult: f64) -> Option<BollingerBands> { todo!() }

/// Percentage deviation of the most recent close from the `period`-bar SMA.
/// Positive = price above MA, negative = below. Returns None if fewer than `period` candles.
pub fn ma_deviation_pct(candles: &[Candle], period: usize) -> Option<f64> { todo!() }

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};

    fn test_candle(open: f64, high: f64, low: f64, close: f64) -> Candle {
        Candle {
            time: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap(),
            open,
            high,
            low,
            close,
            volume: 1,
        }
    }

    #[test]
    fn adx_returns_none_when_buffer_too_small() {
        todo!()
    }

    #[test]
    fn adx_strong_uptrend_returns_high_value() {
        todo!()
    }

    #[test]
    fn adx_choppy_market_returns_low_value() {
        todo!()
    }

    #[test]
    fn atr_pct_basic_calculation() {
        todo!()
    }

    #[test]
    fn bollinger_centered_price_position_is_half() {
        todo!()
    }

    #[test]
    fn ma_deviation_above_ma_returns_positive() {
        todo!()
    }

    #[test]
    fn ma_deviation_below_ma_returns_negative() {
        todo!()
    }
}