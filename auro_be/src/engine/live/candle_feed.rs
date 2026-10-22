//! The live candle feed: the one path by which closed bars reach buffers, the
//! DB and the strategy evaluator.
//!
//! Every cycle it asks OANDA for the complete candles that closed since the
//! last one it saw. Bars are therefore the same OANDA candles the historical
//! backfill stores, so live evaluation and backtests see identical data, and
//! any gap (downtime, a failed request) heals on the next cycle.
//!
//! Two lanes share that one ingest path and never poll the same key at once:
//!
//! * the **fast lane** owns every (instrument, granularity) with an enabled
//!   live strategy. A handful of requests, fired two seconds past each minute
//!   with an immediate retry, so a just-closed bar reaches the evaluator in
//!   seconds rather than wherever it fell in the full sweep;
//! * the **sweep** owns everything else: the full universe at every
//!   granularity, kept warm for regimes, backfills and future strategies.
//!   Its cycle can overrun a minute when OANDA is slow; that no longer delays
//!   trading.
//!
//! The fast lane re-reads the enabled set each minute and publishes it; the
//! sweep skips those keys. When a key changes lane its new owner starts from
//! the newest stored bar, and `CandleBuffer::push` drops any bar it already
//! holds, so a hand-over can never double-ingest or double-evaluate a bar.

use std::collections::{HashMap, HashSet};
use std::str::FromStr;
use std::sync::Arc;

use chrono::{DateTime, Duration, Utc};
use futures_util::stream::{self, StreamExt};
use futures_util::FutureExt;
use tokio::sync::RwLock;
use tokio::time::sleep;

use crate::brokers::oanda::backfill::fetch_complete_since;
use crate::brokers::oanda::INSTRUMENTS;
use crate::db::repositories::{candles as candles_repo, live_queries, signal_events};
use crate::engine::types::{Candle, CandleBuffer, CandleRow, Granularity};
use crate::state::AppState;

use super::evaluator::EvalScope;
use super::{evaluate_and_apply, prefill};

/// Concurrent OANDA requests per cycle.
const CONCURRENCY: usize = 8;

/// Seconds after each minute boundary to poll, giving OANDA time to mark the
/// just-closed bar complete.
const POLL_OFFSET_SECS: i64 = 2;

/// Extra attempts the fast lane makes when a fetch fails, before giving the
/// bar up to the next minute. The sweep makes none: it heals next cycle.
const FAST_LANE_RETRIES: u32 = 3;
const RETRY_DELAY: std::time::Duration = std::time::Duration::from_secs(1);

type FeedKey = (&'static str, Granularity);

/// The keys the fast lane currently owns, published for the sweep to skip.
type LiveKeys = Arc<RwLock<HashSet<FeedKey>>>;

pub fn spawn_candle_feed(state: AppState) {
    tokio::spawn(async move {
        prefill::run_prefill_rules(&state).await;
        prefill::run_prefill_open_positions(&state).await;
        prefill::run_prefill_buffers(&state).await;

        tracing::info!(
            "Candle feed started ({} instruments x {} granularities)",
            INSTRUMENTS.len(),
            Granularity::ALL.len()
        );

        let live_keys: LiveKeys = Arc::new(RwLock::new(HashSet::new()));
        tokio::spawn(fast_lane(state.clone(), live_keys.clone()));
        sweep(state, live_keys).await;
    });
}

/// Poll the enabled-strategy keys two seconds past every minute.
async fn fast_lane(state: AppState, live_keys: LiveKeys) {
    let mut last_seen: HashMap<FeedKey, DateTime<Utc>> = HashMap::new();
    let mut owned: HashSet<FeedKey> = HashSet::new();

    loop {
        sleep(until_next_poll(Utc::now())).await;

        match live_queries::enabled_strategy_keys(&state.db).await {
            Ok(rows) => {
                let keys = live_feed_keys(&rows);
                if keys != owned {
                    tracing::info!(
                        "Fast lane now polling {} keys: {:?}",
                        keys.len(),
                        keys.iter()
                            .map(|(i, g)| format!("{i} {g}"))
                            .collect::<Vec<_>>()
                    );
                    owned = keys;
                    *live_keys.write().await = owned.clone();
                    last_seen.retain(|key, _| owned.contains(key));
                }
            }
            // Keep polling the last known set rather than go dark.
            Err(e) => tracing::warn!("Fast lane could not read enabled strategies: {e}"),
        }

        let keys: Vec<FeedKey> = owned.iter().copied().collect();
        run_keys(&state, keys, &mut last_seen, FAST_LANE_RETRIES).await;
    }
}

/// Poll everything the fast lane does not own, one full pass per cycle.
async fn sweep(state: AppState, live_keys: LiveKeys) {
    let mut last_seen: HashMap<FeedKey, DateTime<Utc>> = HashMap::new();

    loop {
        let skip = live_keys.read().await.clone();
        last_seen.retain(|key, _| !skip.contains(key));
        run_keys(&state, sweep_keys(&skip), &mut last_seen, 0).await;
        sleep(until_next_poll(Utc::now())).await;
    }
}

/// Enabled-strategy rows as feed keys. Rows for instruments or granularities
/// the feed does not poll are dropped: the sweep cannot serve them either.
fn live_feed_keys(rows: &[(String, String)]) -> HashSet<FeedKey> {
    rows.iter()
        .filter_map(|(instrument, granularity)| {
            let instrument = INSTRUMENTS.iter().find(|i| **i == instrument)?;
            let granularity = Granularity::from_str(granularity).ok()?;
            Some((*instrument, granularity))
        })
        .collect()
}

/// The full universe minus the fast lane's keys.
fn sweep_keys(skip: &HashSet<FeedKey>) -> Vec<FeedKey> {
    INSTRUMENTS
        .iter()
        .flat_map(|instrument| Granularity::ALL.iter().map(move |g| (*instrument, *g)))
        .filter(|key| !skip.contains(key))
        .collect()
}

async fn run_keys(
    state: &AppState,
    keys: Vec<FeedKey>,
    last_seen: &mut HashMap<FeedKey, DateTime<Utc>>,
    retries: u32,
) {
    let polls: Vec<_> = keys
        .into_iter()
        .map(|key| {
            let after = last_seen.get(&key).copied();
            poll_key(state, key, after, retries).map(move |newest| (key, newest))
        })
        .collect();

    let updates: Vec<(FeedKey, Option<DateTime<Utc>>)> = stream::iter(polls)
        .buffer_unordered(CONCURRENCY)
        .collect()
        .await;

    for (key, newest) in updates {
        if let Some(newest) = newest {
            last_seen.insert(key, newest);
        }
    }
}

/// Fetch, persist and ingest new bars for one instrument/granularity.
/// Returns the newest bar time now known, or None if the lookup failed.
async fn poll_key(
    state: &AppState,
    (instrument, granularity): FeedKey,
    after: Option<DateTime<Utc>>,
    retries: u32,
) -> Option<DateTime<Utc>> {
    let after = match after {
        Some(t) => t,
        None => match starting_point(state, instrument, granularity).await {
            Some(t) => t,
            None => return None,
        },
    };

    let mut attempts_left = retries;
    let candles = loop {
        match fetch_complete_since(&state.oanda, instrument, granularity, after).await {
            Ok(c) => break c,
            Err(e) if attempts_left > 0 => {
                attempts_left -= 1;
                tracing::warn!(
                    "Candle feed fetch failed for {instrument} {granularity}, retrying: {e}"
                );
                sleep(RETRY_DELAY).await;
            }
            Err(e) => {
                tracing::warn!("Candle feed fetch failed for {instrument} {granularity}: {e}");
                return Some(after);
            }
        }
    };

    let Some(newest) = candles.last().map(|c| c.time) else {
        return Some(after);
    };

    if let Err(e) = ingest_closed_candles(state, instrument, granularity, candles).await {
        tracing::error!("Candle feed persist failed for {instrument} {granularity}: {e}");
        // Leave the cursor unchanged so the next cycle refetches these bars.
        return Some(after);
    }

    Some(newest)
}

/// Where to start fetching for a key the feed hasn't seen this run: the newest
/// stored bar, or — for a key with no history — one buffer's worth back.
async fn starting_point(
    state: &AppState,
    instrument: &str,
    granularity: Granularity,
) -> Option<DateTime<Utc>> {
    match candles_repo::latest_candle_time(&state.db, instrument, granularity).await {
        Ok(Some(t)) => Some(t),
        Ok(None) => Some(
            Utc::now()
                - Duration::minutes(granularity.minutes() * granularity.buffer_capacity() as i64),
        ),
        Err(e) => {
            tracing::warn!("Candle feed could not read latest {instrument} {granularity}: {e}");
            None
        }
    }
}

/// Persist closed bars, append them to the instrument's buffer (if it is in
/// the strategy universe), and evaluate strategies on them:
///
/// * the newest bar, if it just closed and was not already in the buffer,
///   gets a full evaluation (entries and exits);
/// * any earlier bar in the batch is catch-up history. It never opens a
///   trade, but while a position is open on this key its exit rules run bar
///   by bar, so a late batch cannot make a position outlive its exit signal.
async fn ingest_closed_candles(
    state: &AppState,
    instrument: &str,
    granularity: Granularity,
    candles: Vec<Candle>,
) -> Result<(), sqlx::Error> {
    let rows: Vec<CandleRow> = candles
        .iter()
        .map(|candle| CandleRow {
            instrument: instrument.to_string(),
            granularity,
            candle: candle.clone(),
        })
        .collect();
    candles_repo::upsert_candles(&state.db, &rows).await?;
    *state.live.last_candle_persisted.write().await = Some(Utc::now());

    let newest_time = candles.last().map(|c| c.time);
    let newest_is_fresh = candles
        .last()
        .is_some_and(|c| just_closed(c, granularity, Utc::now()));
    let key = (instrument.to_string(), granularity);

    for candle in candles {
        let is_newest = Some(candle.time) == newest_time;
        let scope = if is_newest {
            newest_is_fresh.then_some(EvalScope::Full)
        } else if has_open_position(state, instrument, granularity).await {
            Some(EvalScope::ExitsOnly)
        } else {
            None
        };

        let snapshot = {
            let mut buffers = state.live.buffers.write().await;
            let Some(buffer) = buffers.get_mut(&key) else {
                return Ok(());
            };
            if !buffer.push(candle) {
                continue;
            }
            scope.map(|scope| (buffer.clone(), scope))
        };

        if let Some((buffer_snapshot, scope)) = snapshot {
            if scope == EvalScope::ExitsOnly {
                tracing::info!(
                    "[CATCH-UP] {instrument} {granularity} bar {} arrived late; checking exits only",
                    buffer_snapshot.candles.last().map(|c| c.time).unwrap_or_default()
                );
            }
            evaluate_bar(state, instrument, granularity, &buffer_snapshot, scope).await;
        }
    }

    Ok(())
}

async fn has_open_position(state: &AppState, instrument: &str, granularity: Granularity) -> bool {
    state
        .live
        .open_positions
        .read()
        .await
        .values()
        .any(|p| p.instrument == instrument && p.granularity == granularity)
}

/// Run the strategies for one key on a buffer snapshot and record what they did.
async fn evaluate_bar(
    state: &AppState,
    instrument: &str,
    granularity: Granularity,
    buffer_snapshot: &CandleBuffer,
    scope: EvalScope,
) {
    let current_price = {
        let quotes = state.live.last_quotes.read().await;
        quotes.get(instrument).map(|q| q.mid)
    }
    .or_else(|| buffer_snapshot.candles.last().map(|c| c.mid.close))
    .unwrap_or_default();

    match evaluate_and_apply(
        state,
        instrument,
        granularity,
        buffer_snapshot,
        current_price,
        scope,
    )
    .await
    {
        Ok(reports) => {
            for report in &reports {
                if let Err(e) = signal_events::record_signal_event(&state.db, report).await {
                    tracing::warn!(
                        "Failed to record signal_event for {} {}: {}",
                        report.instrument,
                        report.granularity,
                        e
                    );
                }
            }
        }
        Err(e) => {
            tracing::error!("Strategy evaluation error for {instrument} {granularity}: {e}");
        }
    }
}

/// A bar "just closed" if its close is no more than one bar-length ago. Bars
/// older than that are catch-up history and must not trigger trades.
fn just_closed(candle: &Candle, granularity: Granularity, now: DateTime<Utc>) -> bool {
    let bar = Duration::minutes(granularity.minutes());
    let close_time = candle.time + bar;
    now - close_time <= bar
}

fn until_next_poll(now: DateTime<Utc>) -> std::time::Duration {
    let into_minute = now.timestamp().rem_euclid(60);
    let mut wait = 60 - into_minute + POLL_OFFSET_SECS;
    if wait > 60 {
        wait -= 60;
    }
    std::time::Duration::from_secs(wait as u64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::types::OHLC;
    use chrono::TimeZone;

    fn candle_at(time: DateTime<Utc>) -> Candle {
        Candle {
            time,
            mid: OHLC {
                open: 1.0,
                high: 1.0,
                low: 1.0,
                close: 1.0,
            },
            volume: 1,
            bid: None,
            ask: None,
        }
    }

    #[test]
    fn just_closed_accepts_bar_within_one_bar_length_of_close() {
        let open = Utc.with_ymd_and_hms(2026, 10, 13, 14, 0, 0).unwrap();
        let c = candle_at(open);
        let close = open + Duration::hours(1);

        assert!(just_closed(
            &c,
            Granularity::H1,
            close + Duration::seconds(2)
        ));
        assert!(just_closed(
            &c,
            Granularity::H1,
            close + Duration::minutes(60)
        ));
        assert!(!just_closed(
            &c,
            Granularity::H1,
            close + Duration::minutes(61)
        ));
    }

    #[test]
    fn just_closed_uses_daily_bar_length_for_d() {
        let open = Utc.with_ymd_and_hms(2026, 10, 12, 21, 0, 0).unwrap();
        let c = candle_at(open);
        let close = open + Duration::days(1);

        assert!(just_closed(
            &c,
            Granularity::D,
            close + Duration::minutes(5)
        ));
        assert!(!just_closed(&c, Granularity::D, close + Duration::days(2)));
    }

    #[test]
    fn live_feed_keys_map_rows_and_drop_unknowns() {
        let rows = vec![
            ("NAS100_USD".to_string(), "M5".to_string()),
            ("NAS100_USD".to_string(), "D".to_string()),
            ("SPY".to_string(), "D".to_string()),
            ("EUR_USD".to_string(), "W".to_string()),
        ];
        let keys = live_feed_keys(&rows);
        assert_eq!(keys.len(), 2);
        assert!(keys.contains(&("NAS100_USD", Granularity::M5)));
        assert!(keys.contains(&("NAS100_USD", Granularity::D)));
    }

    #[test]
    fn sweep_skips_the_fast_lane_keys() {
        let live: HashSet<FeedKey> = [("NAS100_USD", Granularity::M5)].into_iter().collect();
        let keys = sweep_keys(&live);
        assert_eq!(keys.len(), INSTRUMENTS.len() * Granularity::ALL.len() - 1);
        assert!(!keys.contains(&("NAS100_USD", Granularity::M5)));
        assert!(keys.contains(&("NAS100_USD", Granularity::M1)));
        assert!(sweep_keys(&HashSet::new()).len() == INSTRUMENTS.len() * Granularity::ALL.len());
    }

    #[test]
    fn next_poll_lands_just_after_the_minute_boundary() {
        let at = |s| Utc.with_ymd_and_hms(2026, 10, 13, 14, 30, s).unwrap();
        assert_eq!(until_next_poll(at(0)).as_secs(), 2);
        assert_eq!(until_next_poll(at(1)).as_secs(), 1);
        assert_eq!(until_next_poll(at(2)).as_secs(), 60);
        assert_eq!(until_next_poll(at(30)).as_secs(), 32);
        assert_eq!(until_next_poll(at(59)).as_secs(), 3);
    }
}
