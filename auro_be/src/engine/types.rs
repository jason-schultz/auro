use std::{
    fmt::{Display, Formatter},
    str::FromStr,
};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Buffer key: (instrument, granularity)
pub type BufferKey = (String, Granularity);

/// Generic candle accumulator that works for any timeframe.
/// Tracks time slot boundaries and emits a close when the slot changes.
#[derive(Debug, Clone)]
pub struct CandleAccumulator {
    /// The time slot we're currently accumulating for
    /// For H1: the hour (0-23). For M15: minutes / 15 combined with hour (0-95 per day).
    pub current_slot: Option<u32>,
    /// Last mid price seen in the current slot
    pub last_mid: f64,
    /// How many M1 closes we've seen this slot
    pub tick_count: u32,
}

impl CandleAccumulator {
    pub fn new() -> Self {
        Self {
            current_slot: None,
            last_mid: 0.0,
            tick_count: 0,
        }
    }

    /// Feed a new M1 close. Returns Some(close_price) if a candle boundary was crossed.
    pub fn on_minute_close(&mut self, slot: u32, mid: f64) -> Option<f64> {
        let result = match self.current_slot {
            Some(prev_slot) if prev_slot != slot => {
                let close = self.last_mid;
                self.tick_count = 0;
                Some(close)
            }
            None => None,
            _ => None,
        };

        self.current_slot = Some(slot);
        self.last_mid = mid;
        self.tick_count += 1;

        result
    }
}

/// Buffer of candle closes used by strategy evaluation.
/// One buffer per (instrument, granularity) pair.
#[derive(Debug, Clone)]
pub struct CandleBuffer {
    pub closes: Vec<f64>,
    pub max_size: usize,
    pub current_mid: f64,
}

impl CandleBuffer {
    pub fn new(max_size: usize) -> Self {
        Self {
            closes: Vec::new(),
            max_size,
            current_mid: 0.0,
        }
    }

    pub fn push(&mut self, close: f64) {
        self.closes.push(close);
        if self.closes.len() > self.max_size {
            self.closes.remove(0);
        }
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
pub struct OpenPosition {
    pub strategy_id: uuid::Uuid,
    pub trade_id: String,
    pub instrument: String,
    pub direction: Direction,
    pub entry_price: f64,
    pub units: String,
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
