use chrono::{DateTime, Timelike, Utc};

use crate::engine::types::Granularity;

/// Calculate the time slot for a given granularity.
/// H1: just the hour (0-23), changes every 60 minutes
/// M15: hour * 4 + (minute / 15), changes every 15 minutes (0-95)
/// M5: hour * 12 + (minute / 5), changes every 5 minutes (0-287)
pub(crate) fn time_slot(granularity: Granularity, hour: u32, minute: u32) -> u32 {
    match granularity {
        Granularity::M1 => hour * 60 + minute,
        Granularity::M5 => hour * 12 + minute / 5,
        Granularity::M15 => hour * 4 + minute / 15,
        Granularity::H1 => hour,
        Granularity::H4 => hour / 4,
        Granularity::D => 0,
    }
}

/// Returns the canonical start time of the slot containing `tick_time`.
pub(crate) fn compute_slot_time(
    granularity: Granularity,
    tick_time: DateTime<Utc>,
) -> DateTime<Utc> {
    match granularity {
        Granularity::H1 => tick_time
            .with_minute(0)
            .unwrap()
            .with_second(0)
            .unwrap()
            .with_nanosecond(0)
            .unwrap(),
        Granularity::M15 => {
            let m = (tick_time.minute() / 15) * 15;
            tick_time
                .with_minute(m)
                .unwrap()
                .with_second(0)
                .unwrap()
                .with_nanosecond(0)
                .unwrap()
        }
        Granularity::D | Granularity::H4 | Granularity::M5 | Granularity::M1 => {
            unimplemented!("compute_slot_time not implemented for {:?}", granularity)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn time_slot_h1_returns_hour() {
        assert_eq!(time_slot(Granularity::H1, 0, 0), 0);
        assert_eq!(time_slot(Granularity::H1, 14, 30), 14);
        assert_eq!(time_slot(Granularity::H1, 23, 59), 23);
    }

    #[test]
    fn time_slot_m15_changes_every_15_minutes() {
        // Hour 0
        assert_eq!(time_slot(Granularity::M15, 0, 0), 0);
        assert_eq!(time_slot(Granularity::M15, 0, 14), 0); // still in first 15-min block
        assert_eq!(time_slot(Granularity::M15, 0, 15), 1); // new block
        assert_eq!(time_slot(Granularity::M15, 0, 30), 2);
        assert_eq!(time_slot(Granularity::M15, 0, 45), 3);
        // Hour 1
        assert_eq!(time_slot(Granularity::M15, 1, 0), 4);
        assert_eq!(time_slot(Granularity::M15, 1, 15), 5);
        // Hour 23
        assert_eq!(time_slot(Granularity::M15, 23, 45), 95);
    }

    #[test]
    fn time_slot_m15_consecutive_minutes_same_slot() {
        // Minutes 0-14 should all be the same slot
        let slot = time_slot(Granularity::M15, 10, 0);
        for m in 0..15 {
            assert_eq!(time_slot(Granularity::M15, 10, m), slot);
        }
        // Minute 15 should be different
        assert_ne!(time_slot(Granularity::M15, 10, 15), slot);
    }

    #[test]
    fn compute_slot_time_h1_returns_start_of_current_hour() {
        let tick = Utc.with_ymd_and_hms(2026, 5, 1, 14, 30, 27).unwrap();
        let expected = Utc.with_ymd_and_hms(2026, 5, 1, 14, 0, 0).unwrap();
        assert_eq!(compute_slot_time(Granularity::H1, tick), expected);
    }

    #[test]
    fn compute_slot_time_m15_returns_start_of_current_15min_block() {
        let tick = Utc.with_ymd_and_hms(2026, 5, 1, 14, 47, 5).unwrap();
        let expected = Utc.with_ymd_and_hms(2026, 5, 1, 14, 45, 0).unwrap();
        assert_eq!(compute_slot_time(Granularity::M15, tick), expected);
    }

    #[test]
    fn compute_slot_time_m15_at_block_boundary() {
        let tick = Utc.with_ymd_and_hms(2026, 5, 1, 14, 0, 0).unwrap();
        let expected = Utc.with_ymd_and_hms(2026, 5, 1, 14, 0, 0).unwrap();
        assert_eq!(compute_slot_time(Granularity::M15, tick), expected);
    }
}
