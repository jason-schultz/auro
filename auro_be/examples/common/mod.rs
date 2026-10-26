//! Helpers shared by the research examples.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, NaiveDate, Utc};
use serde_json::Value;

/// Daily closes for a Yahoo index symbol (without the `^`), cached under
/// target/research_cache/yahoo so a rerun reads the same data.
pub async fn yahoo_closes(
    symbol: &str,
) -> Result<BTreeMap<NaiveDate, f64>, Box<dyn std::error::Error>> {
    let cache = Path::new("target/research_cache/yahoo").join(format!("{symbol}.json"));
    let body = match std::fs::read_to_string(&cache) {
        Ok(body) => body,
        Err(_) => {
            let url = format!(
                "https://query2.finance.yahoo.com/v8/finance/chart/%5E{symbol}?period1=473385600&period2={}&interval=1d",
                Utc::now().timestamp()
            );
            let body = reqwest::Client::new()
                .get(url)
                .header("User-Agent", "Mozilla/5.0")
                .send()
                .await?
                .error_for_status()?
                .text()
                .await?;
            std::fs::create_dir_all(cache.parent().expect("cache dir"))?;
            std::fs::write(&cache, &body)?;
            body
        }
    };
    let v: Value = serde_json::from_str(&body)?;
    let result = &v["chart"]["result"][0];
    let offset = result["meta"]["gmtoffset"].as_i64().unwrap_or(0);
    let stamps = result["timestamp"].as_array().ok_or("no timestamps")?;
    let closes = result["indicators"]["quote"][0]["close"]
        .as_array()
        .ok_or("no closes")?;
    Ok(stamps
        .iter()
        .zip(closes)
        .filter_map(|(t, c)| {
            let date = DateTime::from_timestamp(t.as_i64()? + offset, 0)?.date_naive();
            Some((date, c.as_f64().filter(|c| *c > 0.0)?))
        })
        .collect())
}

pub fn mean_std(xs: &[f64]) -> (f64, f64) {
    let n = xs.len() as f64;
    let mean = xs.iter().sum::<f64>() / n;
    let var = xs.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / (n - 1.0);
    (mean, var.sqrt())
}
