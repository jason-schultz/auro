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

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct OHLC {
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
}

#[derive(Debug, Clone)]
pub struct Candle {
    pub time: DateTime<Utc>,
    pub mid: OHLC,
    pub volume: i32,
    pub bid: Option<OHLC>,
    pub ask: Option<OHLC>,
}

impl Candle {
    pub fn entry_fill_price(&self, direction: Direction) -> f64 {
        match direction {
            Direction::Long => self.ask.as_ref().map(|a| a.close).unwrap_or(self.mid.close),
            Direction::Short => self.bid.as_ref().map(|b| b.close).unwrap_or(self.mid.close),
        }
    }

    pub fn exit_fill_price(&self, direction: Direction) -> f64 {
        match direction {
            Direction::Long => self.bid.as_ref().map(|b| b.close).unwrap_or(self.mid.close),
            Direction::Short => self.ask.as_ref().map(|a| a.close).unwrap_or(self.mid.close),
        }
    }

    pub fn sl_check_price(&self, direction: Direction) -> f64 {
        match direction {
            Direction::Long => self.bid.as_ref().map(|b| b.low).unwrap_or(self.mid.low),
            Direction::Short => self.ask.as_ref().map(|a| a.high).unwrap_or(self.mid.high),
        }
    }

    pub fn tp_check_price(&self, direction: Direction) -> f64 {
        match direction {
            Direction::Long => self.ask.as_ref().map(|a| a.high).unwrap_or(self.mid.high),
            Direction::Short => self.bid.as_ref().map(|b| b.low).unwrap_or(self.mid.low),
        }
    }

    pub fn directional_open(&self, direction: Direction) -> f64 {
        match direction {
            Direction::Long => self.bid.as_ref().map(|b| b.open).unwrap_or(self.mid.open),
            Direction::Short => self.ask.as_ref().map(|a| a.open).unwrap_or(self.mid.open),
        }
    }
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
        bid: f64,
        ask: f64,
    ) -> Option<Candle> {
        match (self.current_slot, &mut self.current_candle) {
            (Some(prev_slot), Some(_)) if prev_slot != slot => {
                let completed = self.current_candle.take();
                self.current_candle = Some(Candle {
                    time: slot_time,
                    mid: OHLC {
                        open: mid,
                        high: mid,
                        low: mid,
                        close: mid,
                    },
                    volume: 1,
                    bid: Some(OHLC {
                        open: bid,
                        high: bid,
                        low: bid,
                        close: bid,
                    }),
                    ask: Some(OHLC {
                        open: ask,
                        high: ask,
                        low: ask,
                        close: ask,
                    }),
                });
                self.current_slot = Some(slot);
                completed
            }
            // First tick ever: Initialize, emit nothing
            (None, _) => {
                self.current_candle = Some(Candle {
                    time: slot_time,
                    mid: OHLC {
                        open: mid,
                        high: mid,
                        low: mid,
                        close: mid,
                    },
                    volume: 1,
                    bid: Some(OHLC {
                        open: bid,
                        high: bid,
                        low: bid,
                        close: bid,
                    }),
                    ask: Some(OHLC {
                        open: ask,
                        high: ask,
                        low: ask,
                        close: ask,
                    }),
                });
                self.current_slot = Some(slot);
                None
            }
            (Some(_), Some(candle)) => {
                // Same slot, update current candle
                candle.mid.high = candle.mid.high.max(mid);
                candle.mid.low = candle.mid.low.min(mid);
                candle.mid.close = mid;
                candle.volume += 1;

                if let Some(bid_ohlc) = candle.bid.as_mut() {
                    bid_ohlc.high = bid_ohlc.high.max(bid);
                    bid_ohlc.low = bid_ohlc.low.min(bid);
                    bid_ohlc.close = bid;
                }
                if let Some(ask_ohlc) = candle.ask.as_mut() {
                    ask_ohlc.high = ask_ohlc.high.max(ask);
                    ask_ohlc.low = ask_ohlc.low.min(ask);
                    ask_ohlc.close = ask;
                }
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
        self.candles.iter().map(|c| c.mid.close).collect()
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
    /// TF (composite shape) long entry — fast/slow MA at the bar of crossover.
    CrossAbove { fast_ma: f64, slow_ma: f64 },
    /// TF (composite shape) short entry.
    CrossBelow { fast_ma: f64, slow_ma: f64 },
    /// MR (composite shape) entry. Direction is on the Trade itself.
    MeanReversionEntry {
        ma_value: f64,
        z_score: f64,
        rsi: f64,
    },
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
    pub const MTF: &'static [Granularity] = &[Granularity::H4, Granularity::H1, Granularity::M15];

    pub const ALL: &'static [Granularity] = &[
        Granularity::M1,
        Granularity::M5,
        Granularity::M15,
        Granularity::H1,
        Granularity::H4,
        Granularity::D,
    ];

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
    pub risk_pct: f64,
    pub max_units: Option<i64>,
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

    pub fn as_str(&self) -> &'static str {
        match self {
            StopLossState::Initial => "Initial",
            StopLossState::Breakeven => "Breakeven",
            StopLossState::Trailing => "Trailing",
            StopLossState::NotApplicable => "NotApplicable",
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
    pub worst_price: f64,
    pub best_price: f64,
    pub transition_failed_at: Option<DateTime<Utc>>,
    pub strategy_type: String,
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

    #[test]
    fn fill_helpers_fallback_to_mid_when_bid_ask_missing() {
        let c = candle(slot_time(0, 0), 100.0);

        assert_eq!(c.entry_fill_price(Direction::Long), 100.0);
        assert_eq!(c.entry_fill_price(Direction::Short), 100.0);
        assert_eq!(c.exit_fill_price(Direction::Long), 100.0);
        assert_eq!(c.exit_fill_price(Direction::Short), 100.0);
        assert_eq!(c.sl_check_price(Direction::Long), 100.0);
        assert_eq!(c.sl_check_price(Direction::Short), 100.0);
        assert_eq!(c.tp_check_price(Direction::Long), 100.0);
        assert_eq!(c.tp_check_price(Direction::Short), 100.0);
        assert_eq!(c.directional_open(Direction::Long), 100.0);
        assert_eq!(c.directional_open(Direction::Short), 100.0);
    }

    #[test]
    fn symmetric_spread_round_trip_costs_about_point_two_percent() {
        let c = Candle {
            time: slot_time(0, 0),
            mid: OHLC {
                open: 100.0,
                high: 100.0,
                low: 100.0,
                close: 100.0,
            },
            volume: 1,
            bid: Some(OHLC {
                open: 99.9,
                high: 99.9,
                low: 99.9,
                close: 99.9,
            }),
            ask: Some(OHLC {
                open: 100.1,
                high: 100.1,
                low: 100.1,
                close: 100.1,
            }),
        };

        let entry = c.entry_fill_price(Direction::Long);
        let exit = c.exit_fill_price(Direction::Long);
        let pnl = (exit - entry) / entry;

        assert!((pnl - (-0.001998001998)).abs() < 1e-9);
    }

    fn slot_time(h: u32, m: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 5, 1, h, m, 0).unwrap()
    }

    fn candle(time: DateTime<Utc>, close: f64) -> Candle {
        Candle {
            time,
            mid: OHLC {
                open: close,
                high: close,
                low: close,
                close,
            },
            volume: 1,
            bid: None,
            ask: None,
        }
    }

    #[test]
    fn accumulator_returns_none_on_first_tick() {
        let mut acc = CandleAccumulator::new();
        assert!(acc
            .on_minute_close(10, slot_time(10, 0), 1.2345, 1.2344, 1.2346)
            .is_none());
    }

    #[test]
    fn accumulator_returns_none_within_same_slot() {
        let mut acc = CandleAccumulator::new();
        let t = slot_time(10, 0);
        acc.on_minute_close(10, t, 1.2345, 1.2344, 1.2346);
        assert!(acc.on_minute_close(10, t, 1.2350, 1.2349, 1.2351).is_none());
        assert!(acc.on_minute_close(10, t, 1.2355, 1.2354, 1.2356).is_none());
    }

    #[test]
    fn accumulator_emits_completed_candle_on_slot_change() {
        let mut acc = CandleAccumulator::new();
        let t10 = slot_time(10, 0);
        acc.on_minute_close(10, t10, 1.2345, 1.2344, 1.2346);
        acc.on_minute_close(10, t10, 1.2360, 1.2358, 1.2362);

        let result = acc
            .on_minute_close(11, slot_time(11, 0), 1.2365, 1.2364, 1.2366)
            .unwrap();
        assert_eq!(result.time, t10);
        assert_eq!(result.mid.open, 1.2345);
        assert_eq!(result.mid.high, 1.2360);
        assert_eq!(result.mid.low, 1.2345);
        assert_eq!(result.mid.close, 1.2360);
        assert_eq!(result.volume, 2);

        let bid = result.bid.unwrap();
        let ask = result.ask.unwrap();
        assert_eq!(bid.open, 1.2344);
        assert_eq!(bid.high, 1.2358);
        assert_eq!(bid.low, 1.2344);
        assert_eq!(bid.close, 1.2358);
        assert_eq!(ask.open, 1.2346);
        assert_eq!(ask.high, 1.2362);
        assert_eq!(ask.low, 1.2346);
        assert_eq!(ask.close, 1.2362);
    }

    #[test]
    fn accumulator_tracks_high_and_low_across_ticks() {
        let mut acc = CandleAccumulator::new();
        let t = slot_time(10, 0);
        acc.on_minute_close(10, t, 1.2345, 1.2343, 1.2347); // open
        acc.on_minute_close(10, t, 1.2400, 1.2397, 1.2403); // new high
        acc.on_minute_close(10, t, 1.2300, 1.2298, 1.2302); // new low
        acc.on_minute_close(10, t, 1.2350, 1.2348, 1.2352); // close

        let result = acc
            .on_minute_close(11, slot_time(11, 0), 1.2360, 1.2358, 1.2362)
            .unwrap();
        assert_eq!(result.mid.open, 1.2345);
        assert_eq!(result.mid.high, 1.2400);
        assert_eq!(result.mid.low, 1.2300);
        assert_eq!(result.mid.close, 1.2350);
        assert_eq!(result.volume, 4);
    }

    #[test]
    fn accumulator_tracks_bid_and_ask_ohlc_across_ticks() {
        let mut acc = CandleAccumulator::new();
        let t = slot_time(10, 0);

        // Tick 1 initializes open for all sides
        acc.on_minute_close(10, t, 1.2000, 1.1998, 1.2002);
        // Tick 2 pushes highs
        acc.on_minute_close(10, t, 1.2020, 1.2019, 1.2024);
        // Tick 3 pushes lows and final close
        acc.on_minute_close(10, t, 1.1980, 1.1977, 1.1983);

        let emitted = acc
            .on_minute_close(11, slot_time(11, 0), 1.2050, 1.2048, 1.2052)
            .unwrap();

        let bid = emitted.bid.unwrap();
        let ask = emitted.ask.unwrap();

        assert_eq!(bid.open, 1.1998);
        assert_eq!(bid.high, 1.2019);
        assert_eq!(bid.low, 1.1977);
        assert_eq!(bid.close, 1.1977);

        assert_eq!(ask.open, 1.2002);
        assert_eq!(ask.high, 1.2024);
        assert_eq!(ask.low, 1.1983);
        assert_eq!(ask.close, 1.1983);
    }

    #[test]
    fn accumulator_tracks_multiple_slots() {
        let mut acc = CandleAccumulator::new();
        let t0 = slot_time(0, 0);
        let t1 = slot_time(1, 0);
        let t2 = slot_time(2, 0);

        acc.on_minute_close(0, t0, 1.1000, 1.0999, 1.1001);
        acc.on_minute_close(0, t0, 1.1050, 1.1049, 1.1051);

        let first = acc.on_minute_close(1, t1, 1.2000, 1.1999, 1.2001).unwrap();
        assert_eq!(first.time, t0);
        assert_eq!(first.mid.open, 1.1000);
        assert_eq!(first.mid.close, 1.1050);

        acc.on_minute_close(1, t1, 1.2200, 1.2198, 1.2202);

        let second = acc.on_minute_close(2, t2, 1.3000, 1.2999, 1.3001).unwrap();
        assert_eq!(second.time, t1);
        assert_eq!(second.mid.open, 1.2000);
        assert_eq!(second.mid.close, 1.2200);
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
