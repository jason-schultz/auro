use chrono::{DateTime, Utc};

/// Buffer key: (instrument, granularity)
pub type BufferKey = (String, String);

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

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Direction {
    Long,
    Short,
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

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct LiveStrategy {
    pub id: uuid::Uuid,
    pub strategy_type: String,
    pub instrument: String,
    pub granularity: String,
    pub parameters: serde_json::Value,
    pub enabled: bool,
    pub max_position_size: String,
}

#[derive(Debug)]
pub struct OpenPosition {
    pub strategy_id: uuid::Uuid,
    pub trade_id: String,
    pub instrument: String,
    pub direction: String,
    pub entry_price: f64,
    pub units: String,
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
