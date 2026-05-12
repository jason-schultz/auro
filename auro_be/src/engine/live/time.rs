use chrono::{DateTime, Timelike, Utc};

use crate::engine::types::Granularity;

/// Calculate the time slot for a given granularity.
/// H1: just the hour (0-23), changes every 60 minutes
/// M15: hour * 4 + (minute / 15), changes every 15 minutes (0-95)
/// M5: hour * 12 + (minute / 5), changes every 5 minutes (0-287)
/// H4: hour / 4, changes every 4 hours (0-5)
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
        Granularity::D => tick_time
            .with_hour(0)
            .unwrap()
            .with_minute(0)
            .unwrap()
            .with_second(0)
            .unwrap()
            .with_nanosecond(0)
            .unwrap(),
        Granularity::H1 => tick_time
            .with_minute(0)
            .unwrap()
            .with_second(0)
            .unwrap()
            .with_nanosecond(0)
            .unwrap(),
        Granularity::M5 => {
            let m = (tick_time.minute() / 5) * 5;
            tick_time
                .with_minute(m)
                .unwrap()
                .with_second(0)
                .unwrap()
                .with_nanosecond(0)
                .unwrap()
        }
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
        Granularity::H4 => {
            let h = (tick_time.hour() / 4) * 4;
            tick_time
                .with_hour(h)
                .unwrap()
                .with_minute(0)
                .unwrap()
                .with_second(0)
                .unwrap()
                .with_nanosecond(0)
                .unwrap()
        }
        Granularity::M1 => {
            let m = tick_time.minute();
            tick_time
                .with_minute(m)
                .unwrap()
                .with_second(0)
                .unwrap()
                .with_nanosecond(0)
                .unwrap()
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

    #[test]
    fn time_slot_m5_changes_every_5_minutes() {
        // Hour 0
        assert_eq!(time_slot(Granularity::M5, 0, 0), 0);
        assert_eq!(time_slot(Granularity::M5, 0, 4), 0); // still in first 5-min block
        assert_eq!(time_slot(Granularity::M5, 0, 5), 1); // new block
        assert_eq!(time_slot(Granularity::M5, 0, 10), 2);
        assert_eq!(time_slot(Granularity::M5, 0, 55), 11);
        // Hour 1
        assert_eq!(time_slot(Granularity::M5, 1, 0), 12);
        assert_eq!(time_slot(Granularity::M5, 1, 5), 13);
        // Hour 23
        assert_eq!(time_slot(Granularity::M5, 23, 55), 287);
    }

    #[test]
    fn time_slot_m5_consecutive_minutes_same_slot() {
        // Minutes 0-4 should all be the same slot
        let slot = time_slot(Granularity::M5, 10, 0);
        for m in 0..5 {
            assert_eq!(time_slot(Granularity::M5, 10, m), slot);
        }
        // Minute 5 starts a new slot
        assert_ne!(time_slot(Granularity::M5, 10, 5), slot);
    }

    #[test]
    fn compute_slot_time_m5_returns_start_of_current_5min_block() {
        let tick = Utc.with_ymd_and_hms(2026, 5, 1, 14, 37, 42).unwrap();
        let expected = Utc.with_ymd_and_hms(2026, 5, 1, 14, 35, 0).unwrap();
        assert_eq!(compute_slot_time(Granularity::M5, tick), expected);
    }

    #[test]
    fn compute_slot_time_m5_at_block_boundary() {
        let tick = Utc.with_ymd_and_hms(2026, 5, 1, 14, 25, 0).unwrap();
        let expected = Utc.with_ymd_and_hms(2026, 5, 1, 14, 25, 0).unwrap();
        assert_eq!(compute_slot_time(Granularity::M5, tick), expected);
    }

    #[test]
    fn time_slot_h4_changes_every_4_hours() {
        assert_eq!(time_slot(Granularity::H4, 0, 0), 0);
        assert_eq!(time_slot(Granularity::H4, 1, 30), 0); // still in first 4h block
        assert_eq!(time_slot(Granularity::H4, 3, 59), 0);
        assert_eq!(time_slot(Granularity::H4, 4, 0), 1); // new block
        assert_eq!(time_slot(Granularity::H4, 7, 59), 1);
        assert_eq!(time_slot(Granularity::H4, 8, 0), 2);
        assert_eq!(time_slot(Granularity::H4, 12, 0), 3);
        assert_eq!(time_slot(Granularity::H4, 16, 0), 4);
        assert_eq!(time_slot(Granularity::H4, 20, 0), 5);
        assert_eq!(time_slot(Granularity::H4, 23, 59), 5);
    }

    #[test]
    fn time_slot_h4_consecutive_hours_same_slot() {
        // Hours 0-3 should all be slot 0
        for h in 0..4 {
            assert_eq!(time_slot(Granularity::H4, h, 0), 0);
        }
        // Hour 4 starts a new slot
        assert_eq!(time_slot(Granularity::H4, 4, 0), 1);
    }

    #[test]
    fn compute_slot_time_h4_returns_start_of_current_4h_block() {
        // Tick at 15:47 should snap to the 12:00 slot
        let tick = Utc.with_ymd_and_hms(2026, 5, 1, 15, 47, 33).unwrap();
        let expected = Utc.with_ymd_and_hms(2026, 5, 1, 12, 0, 0).unwrap();
        assert_eq!(compute_slot_time(Granularity::H4, tick), expected);
    }

    #[test]
    fn compute_slot_time_h4_at_block_boundary() {
        // Tick exactly at 08:00 should return 08:00
        let tick = Utc.with_ymd_and_hms(2026, 5, 1, 8, 0, 0).unwrap();
        let expected = Utc.with_ymd_and_hms(2026, 5, 1, 8, 0, 0).unwrap();
        assert_eq!(compute_slot_time(Granularity::H4, tick), expected);
    }

    #[test]
    fn compute_slot_time_h4_all_blocks() {
        // Verify all six 4h blocks in a day snap to the right start hour
        let cases = [
            (1, 0),   // 01:xx → 00:00
            (5, 4),   // 05:xx → 04:00
            (9, 8),   // 09:xx → 08:00
            (13, 12), // 13:xx → 12:00
            (17, 16), // 17:xx → 16:00
            (21, 20), // 21:xx → 20:00
        ];
        for (tick_hour, expected_hour) in cases {
            let tick = Utc.with_ymd_and_hms(2026, 5, 1, tick_hour, 30, 0).unwrap();
            let expected = Utc
                .with_ymd_and_hms(2026, 5, 1, expected_hour, 0, 0)
                .unwrap();
            assert_eq!(
                compute_slot_time(Granularity::H4, tick),
                expected,
                "tick_hour={tick_hour}"
            );
        }
    }
}
