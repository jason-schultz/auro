use crate::engine::types::Granularity;

pub fn default_exit_confirm_bars(granularity: Granularity) -> usize {
    match granularity {
        Granularity::M1 => 60,
        Granularity::M5 => 24,
        Granularity::M15 => 12,
        Granularity::H1 => 4,
        Granularity::H4 => 3,
        Granularity::D => 2,
    }
}

pub fn default_trailing_k(strategy_type: &str) -> f64 {
    match strategy_type {
        "trend_following" => 2.5,
        "mean_reversion" => 1.2,
        _ => 2.0,
    }
}
