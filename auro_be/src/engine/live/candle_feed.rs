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
//! Neither lane asks for a key until its next bar can have closed: the newest
//! stored bar opened at T, so the one after it closes at T + two bar lengths.
//! A daily bar is requested around its close, not every minute of the day.
//! When a due key comes back empty (a session break, the weekend gap, a bar
//! OANDA hasn't marked complete yet) the fast lane asks again next minute and
//! the sweep backs off one bar length, at most five minutes.
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
use crate::brokers::oanda::{is_forex_market_open_at, INSTRUMENTS};
use crate::db::repositories::{candles as candles_repo, live_queries, signal_events};
use crate::engine::daily_bars;
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

/// How long after the weekly close the feed keeps polling, so the final
/// bars (and Friday's daily bar) land before it goes quiet.
const CLOSE_GRACE: Duration = Duration::minutes(15);

/// Longest the sweep waits before asking again after a due key came back empty.
const EMPTY_BACKOFF_CAP: Duration = Duration::minutes(5);

/// Margin on a backoff, so a cycle that starts a moment early still counts.
const CYCLE_SLACK: Duration = Duration::seconds(30);

type FeedKey = (&'static str, Granularity);

/// The keys the fast lane currently owns, published for the sweep to skip.
type LiveKeys = Arc<RwLock<HashSet<FeedKey>>>;

/// Which lane is polling: they differ only in how they handle a miss.
#[derive(Clone, Copy)]
enum Lane {
    Fast,
    Sweep,
}

impl Lane {
    /// Extra attempts after a failed fetch.
    fn retries(self) -> u32 {
        match self {
            Lane::Fast => FAST_LANE_RETRIES,
            Lane::Sweep => 0,
        }
    }

    /// When to ask again after a due key came back with nothing new.
    fn quiet_until(self, granularity: Granularity, cycle: DateTime<Utc>) -> Option<DateTime<Utc>> {
        match self {
            Lane::Fast => None,
            Lane::Sweep => {
                let bar = Duration::minutes(granularity.minutes());
                Some(cycle + bar.min(EMPTY_BACKOFF_CAP) - CYCLE_SLACK)
            }
        }
    }
}

/// What a lane knows about one key between cycles.
#[derive(Clone, Copy)]
struct Cursor {
    /// Open time of the newest bar stored.
    newest: DateTime<Utc>,
    /// Set after an empty answer: don't ask again before this.
    quiet_until: Option<DateTime<Utc>>,
}

impl Cursor {
    fn at(newest: DateTime<Utc>) -> Self {
        Cursor {
            newest,
            quiet_until: None,
        }
    }
}

/// Attempts at the startup open-position load before carrying on without it
/// (entries then wait for the minute-by-minute position sync).
const PREFILL_ATTEMPTS: u32 = 3;

/// Prefill, then run both lanes. Runs forever; started under a supervisor
/// (`engine::live::spawn_supervised`), and the two lanes share this task so
/// a panic in either restarts both together.
pub async fn run_candle_feed(state: AppState) {
    prefill::run_prefill_rules(&state).await;
    for attempt in 1..=PREFILL_ATTEMPTS {
        if prefill::run_prefill_open_positions(&state).await {
            break;
        }
        if attempt < PREFILL_ATTEMPTS {
            sleep(std::time::Duration::from_secs(5 * u64::from(attempt))).await;
        }
    }
    prefill::run_prefill_buffers(&state).await;

    tracing::info!(
        "Candle feed started ({} instruments x {} granularities)",
        INSTRUMENTS.len(),
        Granularity::ALL.len()
    );

    let live_keys: LiveKeys = Arc::new(RwLock::new(HashSet::new()));
    tokio::join!(
        fast_lane(state.clone(), live_keys.clone()),
        sweep(state, live_keys)
    );
}

/// Poll the enabled-strategy keys two seconds past every minute.
async fn fast_lane(state: AppState, live_keys: LiveKeys) {
    let mut cursors: HashMap<FeedKey, Cursor> = HashMap::new();
    let mut owned: HashSet<FeedKey> = HashSet::new();

    loop {
        sleep(until_next_poll(Utc::now())).await;
        if !should_poll(Utc::now()) {
            continue;
        }

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
                    cursors.retain(|key, _| owned.contains(key));
                }
            }
            // Keep polling the last known set rather than go dark.
            Err(e) => tracing::warn!("Fast lane could not read enabled strategies: {e}"),
        }

        let keys: Vec<FeedKey> = owned.iter().copied().collect();
        run_keys(&state, keys, &mut cursors, Lane::Fast).await;
    }
}

/// Poll everything the fast lane does not own, one full pass per cycle.
async fn sweep(state: AppState, live_keys: LiveKeys) {
    let mut cursors: HashMap<FeedKey, Cursor> = HashMap::new();

    loop {
        if !should_poll(Utc::now()) {
            sleep(until_next_poll(Utc::now())).await;
            continue;
        }
        let skip = live_keys.read().await.clone();
        cursors.retain(|key, _| !skip.contains(key));
        run_keys(&state, sweep_keys(&skip), &mut cursors, Lane::Sweep).await;
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
    cursors: &mut HashMap<FeedKey, Cursor>,
    lane: Lane,
) {
    let cycle = Utc::now();
    let polls: Vec<_> = keys
        .into_iter()
        .filter(|key| is_due(cursors.get(key), key.1, cycle))
        .map(|key| {
            let after = cursors.get(&key).map(|c| c.newest);
            poll_key(state, key, after, lane, cycle).map(move |cursor| (key, cursor))
        })
        .collect();

    let updates: Vec<(FeedKey, Option<Cursor>)> = stream::iter(polls)
        .buffer_unordered(CONCURRENCY)
        .collect()
        .await;

    for (key, cursor) in updates {
        if let Some(cursor) = cursor {
            cursors.insert(key, cursor);
        }
    }
}

/// Whether a key is worth asking about this cycle. A key the lane hasn't
/// seen yet always is; otherwise its next bar must be able to have closed,
/// and any backoff from an empty answer must have run out.
fn is_due(cursor: Option<&Cursor>, granularity: Granularity, now: DateTime<Utc>) -> bool {
    let Some(cursor) = cursor else {
        return true;
    };
    let bar = Duration::minutes(granularity.minutes());
    now >= cursor.newest + bar + bar && cursor.quiet_until.is_none_or(|t| now >= t)
}

/// Fetch, persist and ingest new bars for one instrument/granularity.
/// Returns the key's cursor for the next cycle, or None if the lookup failed.
async fn poll_key(
    state: &AppState,
    (instrument, granularity): FeedKey,
    after: Option<DateTime<Utc>>,
    lane: Lane,
    cycle: DateTime<Utc>,
) -> Option<Cursor> {
    let after = match after {
        Some(t) => t,
        None => match starting_point(state, instrument, granularity).await {
            Some(t) => t,
            None => return None,
        },
    };

    let mut attempts_left = lane.retries();
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
                return Some(Cursor::at(after));
            }
        }
    };

    let Some(newest) = candles.last().map(|c| c.time) else {
        return Some(Cursor {
            newest: after,
            quiet_until: lane.quiet_until(granularity, cycle),
        });
    };

    if let Err(e) = ingest_closed_candles(state, instrument, granularity, candles).await {
        tracing::error!("Candle feed persist failed for {instrument} {granularity}: {e}");
        // Leave the cursor unchanged so the next cycle refetches these bars.
        return Some(Cursor::at(after));
    }

    Some(Cursor::at(newest))
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
        // A late newest bar can't open a trade, but an open position still
        // takes its exit on it, like any catch-up bar.
        let scope = if is_newest && newest_is_fresh {
            Some(EvalScope::Full)
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
            // The weekend's stub bar waits at the end of the buffer for the
            // bar after it, then folds into it (`daily_bars`), as the loaders
            // fold stored history.
            let candle = match buffer.candles.last() {
                Some(last)
                    if candle.time > last.time
                        && daily_bars::is_stub(instrument, granularity, last) =>
                {
                    let merged = daily_bars::merge(last, &candle);
                    buffer.candles.pop();
                    merged
                }
                _ => candle,
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

/// Longest a bar's close may be past for it to still open a trade: the
/// backtest fills at the close, so an entry long after it (a daily bar seen
/// hours late after a restart) trades a price the strategy never tested.
const ENTRY_LATENESS_CAP: Duration = Duration::minutes(15);

/// A bar "just closed" if its close is no more than one bar-length ago, and
/// never more than `ENTRY_LATENESS_CAP`. Older bars are catch-up history and
/// must not trigger trades.
fn just_closed(candle: &Candle, granularity: Granularity, now: DateTime<Utc>) -> bool {
    let bar = Duration::minutes(granularity.minutes());
    let close_time = candle.time + bar;
    now - close_time <= bar.min(ENTRY_LATENESS_CAP)
}

/// Poll while OANDA's weekly session is open and for a short grace after
/// it closes. Over the weekend every answer is empty, so the feed sleeps;
/// on Sunday's open it fetches everything since the last stored bar.
fn should_poll(now: DateTime<Utc>) -> bool {
    is_forex_market_open_at(now) || is_forex_market_open_at(now - CLOSE_GRACE)
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
    fn just_closed_accepts_a_bar_up_to_the_lateness_cap() {
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
            close + Duration::minutes(15)
        ));
        assert!(!just_closed(
            &c,
            Granularity::H1,
            close + Duration::minutes(16)
        ));
        // A 5-minute bar is late after one bar length, before the cap.
        let m5 = candle_at(open);
        let m5_close = open + Duration::minutes(5);
        assert!(just_closed(
            &m5,
            Granularity::M5,
            m5_close + Duration::minutes(5)
        ));
        assert!(!just_closed(
            &m5,
            Granularity::M5,
            m5_close + Duration::minutes(6)
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
        // Hours late is too late to enter on, though within a day.
        assert!(!just_closed(&c, Granularity::D, close + Duration::hours(3)));
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
    fn feed_sleeps_through_the_weekend_with_a_grace_after_the_close() {
        // Friday 2026-10-23: 17:00 New York is 21:00 UTC (daylight time).
        let at = |d, h, m| Utc.with_ymd_and_hms(2026, 10, d, h, m, 0).unwrap();
        assert!(should_poll(at(23, 20, 59)), "Friday before the close");
        assert!(should_poll(at(23, 21, 10)), "within the grace");
        assert!(!should_poll(at(23, 21, 16)), "after the grace");
        assert!(!should_poll(at(24, 15, 0)), "Saturday");
        assert!(!should_poll(at(25, 20, 59)), "Sunday before the open");
        assert!(should_poll(at(25, 21, 0)), "Sunday open");
        assert!(should_poll(at(21, 3, 0)), "midweek");
        // Standard time: 17:00 New York is 22:00 UTC (Friday 2026-11-06).
        let nov = Utc.with_ymd_and_hms(2026, 11, 6, 21, 30, 0).unwrap();
        assert!(should_poll(nov), "still open at 16:30 New York");
    }

    #[test]
    fn a_key_is_due_once_its_next_bar_can_have_closed() {
        let at = |h, m, s| Utc.with_ymd_and_hms(2026, 10, 27, h, m, s).unwrap();
        // Newest M5 bar opened 14:00; the 14:05 bar closes at 14:10.
        let m5 = Cursor::at(at(14, 0, 0));
        assert!(!is_due(Some(&m5), Granularity::M5, at(14, 9, 2)));
        assert!(is_due(Some(&m5), Granularity::M5, at(14, 10, 2)));

        // Newest daily bar opened Monday 21:00 UTC: next due Wednesday 21:00.
        let d = Cursor::at(at(21, 0, 0) - Duration::days(1));
        assert!(!is_due(
            Some(&d),
            Granularity::D,
            at(21, 0, 2) + Duration::hours(23)
        ));
        assert!(is_due(
            Some(&d),
            Granularity::D,
            at(21, 0, 2) + Duration::days(1)
        ));

        assert!(
            is_due(None, Granularity::D, at(3, 0, 2)),
            "unseen keys are always due"
        );
    }

    #[test]
    fn the_sweep_backs_off_after_an_empty_answer_and_the_fast_lane_does_not() {
        let cycle = Utc.with_ymd_and_hms(2026, 10, 27, 14, 0, 2).unwrap();
        let stale = cycle - Duration::days(3);
        let next_cycle = |minutes| cycle + Duration::minutes(minutes);

        let quiet = |lane: Lane, g| Cursor {
            newest: stale,
            quiet_until: lane.quiet_until(g, cycle),
        };

        // One bar length, capped at five minutes.
        let h1 = quiet(Lane::Sweep, Granularity::H1);
        assert!(!is_due(Some(&h1), Granularity::H1, next_cycle(4)));
        assert!(is_due(Some(&h1), Granularity::H1, next_cycle(5)));
        let m1 = quiet(Lane::Sweep, Granularity::M1);
        assert!(is_due(Some(&m1), Granularity::M1, next_cycle(1)));

        // A cycle that starts a moment early still counts.
        let early = next_cycle(5) - Duration::milliseconds(5);
        assert!(is_due(Some(&h1), Granularity::H1, early));

        let fast = quiet(Lane::Fast, Granularity::D);
        assert!(is_due(Some(&fast), Granularity::D, next_cycle(1)));
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
