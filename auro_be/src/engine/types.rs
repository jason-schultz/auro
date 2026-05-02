use std::{
    fmt::{Display, Formatter},
    str::FromStr,
};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub struct BollingerBands {
    pub upper: f64,
    pub middle: f64,
    pub lower: f64,
    pub bandwith_pct: f64,  // (upper - lower) / middle * 100
    pub position: f64       // (close - lower) / (upper -lower)
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
    pub volume: u32,
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
    pub fn on_minute_close(&mut self, slot: u32, slot_time: DateTime<Utc>,mid: f64) -> Option<Candle> {
        match(self.current_slot, &mut self.current_candle) {
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
