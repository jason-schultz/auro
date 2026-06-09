pub fn granularity_to_minutes(granularity: String) -> usize {
    match granularity.as_str() {
        "M1" => 1,
        "M5" => 5,
        "M15" => 15,
        "M30" => 30,
        "H1" => 60,
        "H4" => 240,
        "D" => 1440,
        n => n[1..].parse().unwrap_or(0),
    }
}
