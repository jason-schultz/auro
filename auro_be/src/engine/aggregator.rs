use std::collections::HashMap;

use chrono::{DateTime, Timelike, Utc};

use crate::oanda::models::CandleRecord;

pub fn aggregate_candles(candles: &[CandleRecord], minutes: usize) -> Vec<CandleRecord> {
    let mut aggregated = Vec::new();
    let mut buckets: HashMap<DateTime<Utc>, Vec<CandleRecord>> = HashMap::new();
    for candle in candles {
        let bucket = snap_to_minutes(candle.timestamp, minutes);
        buckets.entry(bucket).or_default().push(candle.clone());
    }
    for (timestamp, chunk) in buckets {
        let first = chunk.first().unwrap();
        let last = chunk.last().unwrap();
        aggregated.push(CandleRecord {
            instrument: first.instrument.clone(),
            granularity: format_granularity(minutes),
            timestamp,
            open: first.open,
            high: chunk
                .iter()
                .map(|c| c.high)
                .fold(f64::NEG_INFINITY, f64::max),
            low: chunk.iter().map(|c| c.low).fold(f64::INFINITY, f64::min),
            close: last.close,
            volume: chunk.iter().map(|c| c.volume).sum(),
            complete: last.complete,
        });
    }
    aggregated.sort_by_key(|c| c.timestamp);
    aggregated
}

fn snap_to_minutes(timestamp: DateTime<Utc>, minutes: usize) -> DateTime<Utc> {
    if minutes >= 1440 {
        // Daily — snap to midnight
        timestamp
            .with_hour(0)
            .unwrap()
            .with_minute(0)
            .unwrap()
            .with_second(0)
            .unwrap()
            .with_nanosecond(0)
            .unwrap()
    } else if minutes >= 60 {
        // Hourly — snap to hour boundary
        let hours = minutes / 60;
        let snapped_hour = (timestamp.hour() as usize / hours) * hours;
        timestamp
            .with_hour(snapped_hour as u32)
            .unwrap()
            .with_minute(0)
            .unwrap()
            .with_second(0)
            .unwrap()
            .with_nanosecond(0)
            .unwrap()
    } else {
        // Sub-hourly — snap to minute boundary
        let minute = timestamp.minute() as usize;
        let snapped_minute = (minute / minutes) * minutes;
        timestamp
            .with_minute(snapped_minute as u32)
            .unwrap()
            .with_second(0)
            .unwrap()
            .with_nanosecond(0)
            .unwrap()
    }
}

fn format_granularity(minutes: usize) -> String {
    match minutes {
        1 => "M1".to_string(),
        5 => "M5".to_string(),
        15 => "M15".to_string(),
        30 => "M30".to_string(),
        60 => "H1".to_string(),
        240 => "H4".to_string(),
        1440 => "D1".to_string(),
        n => format!("M{}", n),
    }
}

pub fn granularity_to_minutes(granularity: String) -> usize {
    match granularity.as_str() {
        "M1" => 1,
        "M5" => 5,
        "M15" => 15,
        "M30" => 30,
        "H1" => 60,
        "H4" => 240,
        "D1" => 1440,
        n => n[1..].parse().unwrap_or(0),
    }
}
