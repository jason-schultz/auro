use std::{
    fmt::{Display, Formatter},
    str::FromStr,
};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct BollingerBands {
    pub upper: f64,
    pub middle: f64,
    pub lower: f64,
    pub bandwidth_pct: f64, // (upper - lower) / middle * 100
    pub position: f64,      // (close - lower) / (upper - lower)
}

/// Buffer key: (instrument, granularity)
pub type BufferKey = (String, Granularity);

#[derive(Debug, Clone)]
pub struct Candle {
    pub time: DateTime<Utc>,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub volume: i32,
}
/// Generic candle accumulator that works for any timeframe.
/// Tracks time slot boundaries and emits a close when the slot changes.
#[derive(Debug, Clone)]
pub struct CandleAccumulator {
    /// The time slot we're currently accumulating for
    /// For H1: the hour (0-23). For M15: minutes / 15 combined with hour (0-95 per day).
    pub current_slot: Option<u32>,
    pub current_candle: Option<Candle>,
}

impl CandleAccumulator {
    pub fn new() -> Self {
        Self {
            current_slot: None,
            current_candle: None,
        }
    }

    /// Feed a new M1 close. Returns Some(close_price) if a candle boundary was crossed.
    pub fn on_minute_close(
        &mut self,
        slot: u32,
        slot_time: DateTime<Utc>,
        mid: f64,
    ) -> Option<Candle> {
        match (self.current_slot, &mut self.current_candle) {
            (Some(prev_slot), Some(_)) if prev_slot != slot => {
                let completed = self.current_candle.take();
                self.current_candle = Some(Candle {
                    time: slot_time,
                    open: mid,
                    high: mid,
                    low: mid,
                    close: mid,
                    volume: 1,
                });
                self.current_slot = Some(slot);
                completed
            }
            // First tick ever: Initialize, emit nothing
            (None, _) => {
                self.current_candle = Some(Candle {
                    time: slot_time,
                    open: mid,
                    high: mid,
                    low: mid,
                    close: mid,
                    volume: 1,
                });
                self.current_slot = Some(slot);
                None
            }
            (Some(_), Some(candle)) => {
                // Same slot, update current candle
                candle.high = candle.high.max(mid);
                candle.low = candle.low.min(mid);
                candle.close = mid;
                candle.volume += 1;
                None
            }
            // Shouldn't happen but compile time exhaustive
            (Some(_), None) => None,
        }
    }
}

impl Default for CandleAccumulator {
    fn default() -> Self {
        Self::new()
    }
}

/// Buffer of candle closes used by strategy evaluation.
/// One buffer per (instrument, granularity) pair.
#[derive(Debug, Clone)]
pub struct CandleBuffer {
    pub candles: Vec<Candle>,
    pub max_size: usize,
    pub current_mid: f64,
}

impl CandleBuffer {
    pub fn new(max_size: usize) -> Self {
        Self {
            candles: Vec::new(),
            max_size,
            current_mid: 0.0,
        }
    }

    pub fn push(&mut self, candle: Candle) {
        self.candles.push(candle);
        if self.candles.len() > self.max_size {
            self.candles.remove(0);
        }
    }

    pub fn closes(&self) -> Vec<f64> {
        self.candles.iter().map(|c| c.close).collect()
    }
}

/// A `Candle` plus the row metadata needed to persist it to the `candles` table.
/// Used at the DB write boundary; in-memory candle flow uses `Candle` directly.
#[derive(Debug, Clone)]
pub struct CandleRow {
    pub instrument: String,
    pub granularity: Granularity,
    pub complete: bool,
    pub candle: Candle,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "varchar", rename_all = "PascalCase")]
pub enum Direction {
    Long,
    Short,
}

impl Direction {
    pub fn as_str(&self) -> &'static str {
        match self {
            Direction::Long => "Long",
            Direction::Short => "Short",
        }
    }
}

impl Display for Direction {
    fn fmt(&self, f: &mut Formatter) -> std::fmt::Result {
        match self {
            Direction::Long => write!(f, "Long"),
            Direction::Short => write!(f, "Short"),
        }
    }
}

impl FromStr for Direction {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "Long" => Ok(Direction::Long),
            "Short" => Ok(Direction::Short),
            _ => Err(format!("Invalid direction: {}", s)),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ExitReason {
    TakeProfit,
    StopLoss,
    TrailingStop,
    TrendReversal,
    TimeExit,
    EndOfData,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum EntryReason {
    BelowMA { ma_value: f64, deviation_pct: f64 },
    CrossAbove { fast_ma: f64, slow_ma: f64 },
    CrossBelow { fast_ma: f64, slow_ma: f64 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "varchar", rename_all = "PascalCase")]
pub enum Granularity {
    M1,
    M5,
    M15,
    H1,
    H4,
    D,
}

impl Granularity {
    pub fn as_str(&self) -> &'static str {
        match self {
            Granularity::M1 => "M1",
            Granularity::M5 => "M5",
            Granularity::M15 => "M15",
            Granularity::H1 => "H1",
            Granularity::H4 => "H4",
            Granularity::D => "D",
        }
    }

    /// The pipeline validation threshold class for this granularity.
    /// D shares H4's thresholds (same swing-trading characteristics, too few daily signals
    /// to warrant a separate class).
    pub fn timeframe_class(&self) -> &'static str {
        match self {
            Granularity::M1 => "M1",
            Granularity::M5 => "M5",
            Granularity::M15 => "M15",
            Granularity::H1 => "H1",
            Granularity::H4 | Granularity::D => "H4",
        }
    }

    /// How many candles to hold in the in-memory buffer for this granularity.
    /// Sized so that each buffer covers roughly the same useful lookback window
    /// and always has enough candles for the longest indicator (ADX-14, MA-60).
    pub fn buffer_capacity(&self) -> usize {
        match self {
            Granularity::M1 => 500,  // ~8 hours
            Granularity::M5 => 500,  // ~42 hours
            Granularity::M15 => 400, // ~4 days
            Granularity::H1 => 200,  // ~8 days
            Granularity::H4 => 100,  // ~17 days
            Granularity::D => 60,    // ~3 months
        }
    }
}

impl Display for Granularity {
    fn fmt(&self, f: &mut Formatter) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl FromStr for Granularity {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "M1" => Ok(Granularity::M1),
            "M5" => Ok(Granularity::M5),
            "M15" => Ok(Granularity::M15),
            "H1" => Ok(Granularity::H1),
            "H4" => Ok(Granularity::H4),
            "D" => Ok(Granularity::D),
            _ => Err(format!("Invalid granularity: {}", s)),
        }
    }
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct LiveStrategy {
    pub id: uuid::Uuid,
    pub strategy_type: String,
    pub instrument: String,
    pub granularity: Granularity,
    pub parameters: serde_json::Value,
    pub enabled: bool,
    pub max_position_size: String,
}

#[derive(Clone, Debug)]
pub enum StopLossState {
    Initial,       // SL/TP as set on entry
    Breakeven,     // SL moved to entry price, TP unchanged
    Trailing,      // SL replaced with trailing, TP removed
    NotApplicable, // mean reversion or other non-managed strategy
}

impl StopLossState {
    pub fn initial_for_strategy_type(strategy_type: &str) -> Self {
        match strategy_type {
            "trend_following" => StopLossState::Initial,
            "mean_reversion" => StopLossState::NotApplicable,
            _ => StopLossState::NotApplicable,
        }
    }
}

#[derive(Clone, Debug)]
pub struct OpenPosition {
    pub strategy_id: uuid::Uuid,
    pub trade_id: String,
    pub instrument: String,
    pub granularity: Granularity,
    pub direction: Direction,
    pub entry_price: f64,
    pub units: String,
    pub stop_loss_state: StopLossState,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SignalAction {
    OpenedLong,
    OpenedShort,
    ClosedLong,
    ClosedShort,
    EntryRejected,
    ExitConditionsNotMet,
}
#[derive(Debug, Clone, Serialize)]
pub struct SignalReport {
    pub strategy_id: Uuid,
    pub strategy_type: String,
    pub instrument: String,
    pub granularity: Granularity,
    pub action: SignalAction,
    pub price: f64,
    pub reason: String,
    pub oanda_trade_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Trade {
    pub direction: Direction,
    pub entry_price: f64,
    pub exit_price: f64,
    pub entry_time: DateTime<Utc>,
    pub exit_time: DateTime<Utc>,
    pub pnl_percent: f64,
    pub entry_reason: EntryReason,
    pub exit_reason: ExitReason,
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn slot_time(h: u32, m: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 5, 1, h, m, 0).unwrap()
    }

    fn candle(time: DateTime<Utc>, close: f64) -> Candle {
        Candle {
            time,
            open: close,
            high: close,
            low: close,
            close,
            volume: 1,
        }
    }

    #[test]
    fn accumulator_returns_none_on_first_tick() {
        let mut acc = CandleAccumulator::new();
        assert!(acc.on_minute_close(10, slot_time(10, 0), 1.2345).is_none());
    }

    #[test]
    fn accumulator_returns_none_within_same_slot() {
        let mut acc = CandleAccumulator::new();
        let t = slot_time(10, 0);
        acc.on_minute_close(10, t, 1.2345);
        assert!(acc.on_minute_close(10, t, 1.2350).is_none());
        assert!(acc.on_minute_close(10, t, 1.2355).is_none());
    }

    #[test]
    fn accumulator_emits_completed_candle_on_slot_change() {
        let mut acc = CandleAccumulator::new();
        let t10 = slot_time(10, 0);
        acc.on_minute_close(10, t10, 1.2345);
        acc.on_minute_close(10, t10, 1.2360);

        let result = acc.on_minute_close(11, slot_time(11, 0), 1.2365).unwrap();
        assert_eq!(result.time, t10);
        assert_eq!(result.open, 1.2345);
        assert_eq!(result.high, 1.2360);
        assert_eq!(result.low, 1.2345);
        assert_eq!(result.close, 1.2360);
        assert_eq!(result.volume, 2);
    }

    #[test]
    fn accumulator_tracks_high_and_low_across_ticks() {
        let mut acc = CandleAccumulator::new();
        let t = slot_time(10, 0);
        acc.on_minute_close(10, t, 1.2345); // open
        acc.on_minute_close(10, t, 1.2400); // new high
        acc.on_minute_close(10, t, 1.2300); // new low
        acc.on_minute_close(10, t, 1.2350); // close

        let result = acc.on_minute_close(11, slot_time(11, 0), 1.2360).unwrap();
        assert_eq!(result.open, 1.2345);
        assert_eq!(result.high, 1.2400);
        assert_eq!(result.low, 1.2300);
        assert_eq!(result.close, 1.2350);
        assert_eq!(result.volume, 4);
    }

    #[test]
    fn accumulator_tracks_multiple_slots() {
        let mut acc = CandleAccumulator::new();
        let t0 = slot_time(0, 0);
        let t1 = slot_time(1, 0);
        let t2 = slot_time(2, 0);

        acc.on_minute_close(0, t0, 1.1000);
        acc.on_minute_close(0, t0, 1.1050);

        let first = acc.on_minute_close(1, t1, 1.2000).unwrap();
        assert_eq!(first.time, t0);
        assert_eq!(first.open, 1.1000);
        assert_eq!(first.close, 1.1050);

        acc.on_minute_close(1, t1, 1.2200);

        let second = acc.on_minute_close(2, t2, 1.3000).unwrap();
        assert_eq!(second.time, t1);
        assert_eq!(second.open, 1.2000);
        assert_eq!(second.close, 1.2200);
    }

    #[test]
    fn candle_buffer_starts_empty() {
        let buf = CandleBuffer::new(10);
        assert_eq!(buf.candles.len(), 0);
    }

    #[test]
    fn candle_buffer_accumulates_candles() {
        let mut buf = CandleBuffer::new(10);
        buf.push(candle(slot_time(0, 0), 1.0));
        buf.push(candle(slot_time(1, 0), 2.0));
        buf.push(candle(slot_time(2, 0), 3.0));
        assert_eq!(buf.closes(), vec![1.0, 2.0, 3.0]);
    }

    #[test]
    fn candle_buffer_respects_max_size() {
        let mut buf = CandleBuffer::new(3);
        buf.push(candle(slot_time(0, 0), 1.0));
        buf.push(candle(slot_time(1, 0), 2.0));
        buf.push(candle(slot_time(2, 0), 3.0));
        buf.push(candle(slot_time(3, 0), 4.0));
        assert_eq!(buf.closes(), vec![2.0, 3.0, 4.0]);
    }

    #[test]
    fn candle_buffer_evicts_oldest_first() {
        let mut buf = CandleBuffer::new(3);
        for i in 0..10 {
            buf.push(candle(slot_time(i, 0), i as f64));
        }
        assert_eq!(buf.closes(), vec![7.0, 8.0, 9.0]);
    }

    #[test]
    fn buffer_capacity_correct_for_all_granularities() {
        assert_eq!(Granularity::M1.buffer_capacity(), 500);
        assert_eq!(Granularity::M5.buffer_capacity(), 500);
        assert_eq!(Granularity::M15.buffer_capacity(), 400);
        assert_eq!(Granularity::H1.buffer_capacity(), 200);
        assert_eq!(Granularity::H4.buffer_capacity(), 100);
        assert_eq!(Granularity::D.buffer_capacity(), 60);
    }

    #[test]
    fn buffer_closes_are_chronological_oldest_to_newest() {
        let mut buf = CandleBuffer::new(5);
        buf.push(candle(slot_time(0, 0), 1.1000)); // oldest
        buf.push(candle(slot_time(1, 0), 1.2000));
        buf.push(candle(slot_time(2, 0), 1.3000)); // newest

        let closes = buf.closes();
        assert_eq!(closes, vec![1.1000, 1.2000, 1.3000]);
        // Evaluators index from the tail: closes[len-1] is the newest close
        assert_eq!(*closes.last().unwrap(), 1.3000);
    }

    #[test]
    fn evaluator_sees_newest_candles_after_overflow() {
        // Fill a small buffer well past capacity to confirm the window slides
        // correctly and a strategy consuming closes[len-period..] gets recent data.
        let capacity = 5;
        let mut buf = CandleBuffer::new(capacity);

        // Push 10 candles with close prices 1.0 through 10.0
        for i in 1..=10u32 {
            buf.push(candle(slot_time(i, 0), i as f64));
        }

        let closes = buf.closes();

        // Buffer should hold exactly `capacity` candles
        assert_eq!(closes.len(), capacity);

        // The window should be the 5 most recent: 6.0, 7.0, 8.0, 9.0, 10.0
        assert_eq!(closes, vec![6.0, 7.0, 8.0, 9.0, 10.0]);

        // Simulate a mean-reversion MA(3): uses closes[len-3..] = [8.0, 9.0, 10.0]
        let ma_period = 3;
        let ma: f64 = closes[closes.len() - ma_period..].iter().sum::<f64>() / ma_period as f64;
        assert_eq!(ma, 9.0); // (8+9+10)/3 — newest 3 candles, not oldest

        // Simulate a trend-following fast MA(2): uses closes[len-2..] = [9.0, 10.0]
        let fast_period = 2;
        let fast_ma: f64 =
            closes[closes.len() - fast_period..].iter().sum::<f64>() / fast_period as f64;
        assert_eq!(fast_ma, 9.5); // (9+10)/2 — newest 2 candles
    }
}
