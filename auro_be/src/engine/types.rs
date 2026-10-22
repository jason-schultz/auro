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
    /// A bar built from trade prices (equities): `mid` carries the OHLC,
    /// bid/ask are unknown. Vendor volumes arrive as floats and are rounded
    /// into the `i32` the `candles` table stores. Vendor structs implement
    /// `TryFrom<&Vendor> for Candle` on top of this.
    pub fn from_trade_bar(time: DateTime<Utc>, mid: OHLC, volume: f64) -> Self {
        Self {
            time,
            mid,
            volume: volume.round().clamp(0.0, f64::from(i32::MAX)) as i32,
            bid: None,
            ask: None,
        }
    }

    /// Ask − bid at the close, when both sides are known.
    pub fn spread(&self) -> Option<f64> {
        Some(self.ask.as_ref()?.close - self.bid.as_ref()?.close)
    }

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

    pub fn directional_open(&self, direction: Direction) -> f64 {
        match direction {
            Direction::Long => self.bid.as_ref().map(|b| b.open).unwrap_or(self.mid.open),
            Direction::Short => self.ask.as_ref().map(|a| a.open).unwrap_or(self.mid.open),
        }
    }
}

/// Buffer of candle closes used by strategy evaluation.
/// One buffer per (instrument, granularity) pair.
#[derive(Debug, Clone)]
pub struct CandleBuffer {
    pub candles: Vec<Candle>,
    pub max_size: usize,
}

impl CandleBuffer {
    pub fn new(max_size: usize) -> Self {
        Self {
            candles: Vec::new(),
            max_size,
        }
    }

    /// Append a bar. Bars are kept in time order and each bar time is held
    /// once: a bar that is not newer than the last one is ignored, so a bar
    /// delivered twice (two feed lanes, a prefill overlap, a retried fetch)
    /// cannot double up inside an indicator window. Returns whether the bar
    /// was appended.
    pub fn push(&mut self, candle: Candle) -> bool {
        if self
            .candles
            .last()
            .is_some_and(|last| candle.time <= last.time)
        {
            return false;
        }
        self.candles.push(candle);
        if self.candles.len() > self.max_size {
            self.candles.remove(0);
        }
        true
    }

    pub fn closes(&self) -> Vec<f64> {
        self.candles.iter().map(|c| c.mid.close).collect()
    }
}

/// A complete `Candle` plus the row metadata needed to persist it to the
/// `candles` table. Only complete candles are ever persisted.
#[derive(Debug, Clone)]
pub struct CandleRow {
    pub instrument: String,
    pub granularity: Granularity,
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
    StopLoss,
    TrendReversal,
    TimeStop,
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
    /// MACD crossover entry metadata.
    MacdCross { macd: f64, signal: f64 },
    /// Donchian breakout entry metadata using prior entry channel bounds.
    DonchianBreakout { channel_high: f64, channel_low: f64 },
    /// Time-series momentum entry: the lookback return in percent.
    Momentum { roc_pct: f64 },
    /// Scheduled-event window entry: the event being traded around.
    EventWindow { event_time: DateTime<Utc> },
    /// Noise-area breakout: band levels and session VWAP at the decision bar.
    NoiseAreaBreakout {
        upper_band: f64,
        lower_band: f64,
        vwap: f64,
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

    /// Bar length in minutes. D is a calendar day; Auro requests D anchored to
    /// the 16:00 New York cash close (see `oanda::client::candle_query`) and
    /// OANDA anchors H4 to its 17:00 rollover, so use this for durations, not
    /// for alignment.
    pub fn minutes(&self) -> i64 {
        match self {
            Granularity::M1 => 1,
            Granularity::M5 => 5,
            Granularity::M15 => 15,
            Granularity::H1 => 60,
            Granularity::H4 => 240,
            Granularity::D => 1440,
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
    /// and always has enough candles for the longest indicator (ADX-14, MA-200).
    pub fn buffer_capacity(&self) -> usize {
        match self {
            Granularity::M1 => 500,  // ~8 hours
            Granularity::M5 => 5000, // ~17 trading days: NoiseArea needs 14 prior sessions
            Granularity::M15 => 400, // ~4 days
            Granularity::H1 => 256,  // supports MA-200 with headroom
            Granularity::H4 => 256,  // supports MA-200 with headroom
            Granularity::D => 300,   // 3× period for EMA convergence on 100-bar indicators
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
}

#[derive(Clone, Debug)]
pub enum StopLossState {
    Trailing,      // SL replaced with trailing, TP removed
    NotApplicable, // mean reversion or other non-managed strategy
}

impl StopLossState {
    pub fn as_str(&self) -> &'static str {
        match self {
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
    pub entry_time: DateTime<Utc>,
    pub units: String,
    pub stop_loss_state: StopLossState,
    pub worst_price: f64,
    pub best_price: f64,
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
    fn push_ignores_bars_not_newer_than_the_last() {
        let mut buf = CandleBuffer::new(10);
        assert!(buf.push(candle(slot_time(0, 0), 1.0)));
        assert!(buf.push(candle(slot_time(1, 0), 2.0)));
        assert!(!buf.push(candle(slot_time(1, 0), 9.0)), "same bar again");
        assert!(!buf.push(candle(slot_time(0, 0), 9.0)), "older bar");
        assert_eq!(buf.closes(), vec![1.0, 2.0]);
        assert!(buf.push(candle(slot_time(2, 0), 3.0)));
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
        assert_eq!(Granularity::M5.buffer_capacity(), 5000);
        assert_eq!(Granularity::M15.buffer_capacity(), 400);
        assert_eq!(Granularity::H1.buffer_capacity(), 256);
        assert_eq!(Granularity::H4.buffer_capacity(), 256);
        assert_eq!(Granularity::D.buffer_capacity(), 300);
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
