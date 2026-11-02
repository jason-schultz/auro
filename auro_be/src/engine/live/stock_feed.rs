//! The live stock bar feed: Questrade's bars as they close during the US
//! session, the way `candle_feed` keeps OANDA's.
//!
//! It covers:
//! - every listing flagged `feed_questrade_bars` at 1 and 5 minutes;
//! - every enabled live strategy on a Questrade listing, at its own
//!   timeframe, first in each cycle and retried (the fast lane's job in the
//!   OANDA feed). None exists yet; share alerts decide on daily bars plus a
//!   live quote.
//!
//! Each key is asked for only once its next bar can have closed, from the
//! newest stored bar on, so a minute costs one short request per due key.
//! Bars go through `brokers::questrade::bars::store`, the same path as the
//! nightly fetch, which stays as reconciliation: it re-pulls the last days
//! and fills anything this feed missed, plus the daily bars (final only
//! hours after the close).
//!
//! Rate limits: the client spaces every request (at most 10 a second, half
//! of Questrade's limit), and the feed holds its sweep back whenever
//! Questrade says fewer than `RESERVE` requests are left in the window, so
//! pages, quotes and nightly jobs keep their share. The client is locked
//! per request, never for a whole cycle, so those callers interleave.

use std::collections::HashMap;

use chrono::{DateTime, Datelike, Duration, Timelike, Utc, Weekday};
use chrono_tz::America::New_York;
use tokio::time::sleep;

use crate::brokers::questrade::bars;
use crate::brokers::questrade::client::QuestradeClient;
use crate::brokers::questrade::identity;
use crate::brokers::questrade::link::SharedClient;
use crate::db::repositories::{
    candles as candles_repo, instruments as instruments_repo, live_queries,
};
use crate::engine::instrument::Instrument;
use crate::engine::session::{session_close_min, SESSION_OPEN_MIN};
use crate::engine::types::Granularity;
use crate::state::AppState;

/// The timeframes kept for every flagged listing.
const SWEEP_GRANULARITIES: [Granularity; 2] = [Granularity::M1, Granularity::M5];

/// Seconds past each minute to poll: Questrade needs a few to finish a bar.
const POLL_OFFSET_SECS: u32 = 5;

/// How long after the close the feed keeps polling for the last bars.
const CLOSE_GRACE_MIN: i64 = 10;

/// Requests left in Questrade's window below which the sweep waits.
const RESERVE: u32 = 1_000;

/// Extra attempts for a live strategy's key before leaving it to next minute.
const FAST_RETRIES: u32 = 2;

/// The longest window one request asks for; older gaps are the nightly
/// reconciliation's.
const MAX_WINDOW: Duration = Duration::days(5);

/// Longest wait before asking again after an empty answer (a halt, a
/// holiday the session check doesn't know).
const EMPTY_BACKOFF_CAP: Duration = Duration::minutes(5);

/// What the feed knows about one key between cycles.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Cursor {
    /// Open time of the newest bar stored.
    newest: DateTime<Utc>,
    /// After an empty answer: don't ask again before this.
    quiet_until: Option<DateTime<Utc>>,
}

type Key = (String, Granularity);

/// Runs forever; started under a supervisor (`spawn_supervised`).
pub async fn run_stock_feed(state: AppState) {
    tracing::info!("Stock bar feed started (Questrade, US session)");
    let mut cursors: HashMap<Key, Cursor> = HashMap::new();
    let mut held_back = false;

    loop {
        sleep(until_next_poll(Utc::now())).await;
        let now = Utc::now();
        if !in_session(now) {
            continue;
        }
        let Some(qt) = state.questrade.client() else {
            continue;
        };

        let (fast, sweep) = match keys(&state).await {
            Ok(keys) => keys,
            Err(e) => {
                tracing::warn!("Stock feed could not read its listings: {e}");
                continue;
            }
        };

        for (instrument, granularity) in &fast {
            poll(
                &state,
                &qt,
                instrument,
                *granularity,
                &mut cursors,
                now,
                FAST_RETRIES,
            )
            .await;
        }

        let remaining = qt.lock().await.rate_remaining();
        if remaining.is_some_and(|left| left < RESERVE) {
            if !held_back {
                tracing::warn!(
                    "Stock feed holding its sweep back: Questrade says {remaining:?} requests left"
                );
            }
            held_back = true;
            continue;
        }
        held_back = false;
        for (instrument, granularity) in &sweep {
            poll(&state, &qt, instrument, *granularity, &mut cursors, now, 0).await;
        }
    }
}

/// The live strategies' keys (fast) and the flagged listings' keys not
/// already among them (sweep).
async fn keys(
    state: &AppState,
) -> Result<
    (
        Vec<(Instrument, Granularity)>,
        Vec<(Instrument, Granularity)>,
    ),
    sqlx::Error,
> {
    let mut fast = Vec::new();
    for (symbol, granularity) in live_queries::enabled_stock_strategy_keys(&state.db).await? {
        let Ok(granularity) = granularity.parse::<Granularity>() else {
            continue;
        };
        if granularity == Granularity::D {
            continue; // final hours after the close: the nightly fetch's
        }
        if let Some(instrument) =
            instruments_repo::find_by_questrade_symbol(&state.db, &symbol).await?
        {
            fast.push((instrument, granularity));
        }
    }

    let sweep = instruments_repo::fed_by_questrade_bars(&state.db)
        .await?
        .into_iter()
        .flat_map(|instrument| SWEEP_GRANULARITIES.map(|g| (instrument.clone(), g)))
        .filter(|(instrument, g)| !fast.iter().any(|(f, fg)| f.id == instrument.id && fg == g))
        .collect();
    Ok((fast, sweep))
}

/// Fetch and store the new closed bars of one key, if it's due.
async fn poll(
    state: &AppState,
    qt: &SharedClient,
    instrument: &Instrument,
    granularity: Granularity,
    cursors: &mut HashMap<Key, Cursor>,
    now: DateTime<Utc>,
    retries: u32,
) {
    let Some(symbol) = instrument.questrade_symbol.clone() else {
        return;
    };
    let key = (symbol.clone(), granularity);
    let cursor = match cursors.get(&key) {
        Some(c) => *c,
        None => match candles_repo::latest_candle_time(&state.db, &symbol, granularity).await {
            Ok(newest) => Cursor {
                newest: newest.unwrap_or(now - MAX_WINDOW),
                quiet_until: None,
            },
            Err(e) => {
                tracing::warn!("Stock feed: newest {symbol} {granularity} bar unknown: {e}");
                return;
            }
        },
    };
    if !is_due(&cursor, granularity, now) {
        cursors.insert(key, cursor);
        return;
    }

    let (from, to) = window(&cursor, granularity, now);
    let mut attempts_left = retries;
    let raw = loop {
        let fetched = {
            let mut client = qt.lock().await;
            match identity::resolve_symbol_id(&mut client, &state.db, instrument).await {
                Ok(id) => {
                    client
                        .get_candles_between(
                            id,
                            from,
                            to,
                            QuestradeClient::interval_for(granularity),
                        )
                        .await
                }
                Err(e) => Err(e),
            }
        };
        match fetched {
            Ok(raw) => break raw,
            Err(e) if attempts_left > 0 => {
                attempts_left -= 1;
                tracing::warn!("Stock feed fetch failed for {symbol} {granularity}, retrying: {e}");
                sleep(std::time::Duration::from_secs(1)).await;
            }
            Err(e) => {
                tracing::warn!("Stock feed fetch failed for {symbol} {granularity}: {e}");
                cursors.insert(key, cursor);
                return;
            }
        }
    };

    let next = match bars::store(&state.db, &symbol, granularity, &raw, now).await {
        Ok(stored) => match stored.rows.last() {
            Some(row) if row.candle.time > cursor.newest => Cursor {
                newest: row.candle.time,
                quiet_until: None,
            },
            _ => Cursor {
                newest: cursor.newest,
                quiet_until: Some(now + backoff(granularity)),
            },
        },
        Err(e) => {
            // Unchanged: the next cycle fetches these bars again.
            tracing::error!("Stock feed store failed for {symbol} {granularity}: {e}");
            cursor
        }
    };
    cursors.insert(key, next);
}

/// Whether a key's next bar can have closed and any backoff is over.
fn is_due(cursor: &Cursor, granularity: Granularity, now: DateTime<Utc>) -> bool {
    let bar = Duration::minutes(granularity.minutes());
    now >= cursor.newest + bar + bar && cursor.quiet_until.is_none_or(|t| now >= t)
}

/// The span to ask for: from the bar after the newest stored, at most
/// `MAX_WINDOW` back, to now.
fn window(
    cursor: &Cursor,
    granularity: Granularity,
    now: DateTime<Utc>,
) -> (DateTime<Utc>, DateTime<Utc>) {
    let from = (cursor.newest + Duration::minutes(granularity.minutes())).max(now - MAX_WINDOW);
    (from, now)
}

fn backoff(granularity: Granularity) -> Duration {
    Duration::minutes(granularity.minutes()).min(EMPTY_BACKOFF_CAP)
}

/// Whether `now` is inside a weekday US regular session, with a few
/// minutes' grace after the close for its last bars. Holidays aren't known
/// here: a closed day answers empty and each key backs off.
fn in_session(now: DateTime<Utc>) -> bool {
    let local = now.with_timezone(&New_York);
    if matches!(local.weekday(), Weekday::Sat | Weekday::Sun) {
        return false;
    }
    let minute = i64::from(local.hour() * 60 + local.minute());
    let close = session_close_min(local.date_naive()) + CLOSE_GRACE_MIN;
    // The first bar closes a minute after the open.
    (SESSION_OPEN_MIN + 1..=close).contains(&minute)
}

/// Time until `POLL_OFFSET_SECS` past the next minute.
fn until_next_poll(now: DateTime<Utc>) -> std::time::Duration {
    let into_minute = now.second() * 1_000 + now.timestamp_subsec_millis() % 1_000;
    let target = POLL_OFFSET_SECS * 1_000;
    let wait = if into_minute < target {
        target - into_minute
    } else {
        60_000 - into_minute + target
    };
    std::time::Duration::from_millis(u64::from(wait))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ny(s: &str) -> DateTime<Utc> {
        chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M")
            .unwrap()
            .and_local_timezone(New_York)
            .unwrap()
            .with_timezone(&Utc)
    }

    #[test]
    fn polls_only_in_the_weekday_session_with_grace_after_the_close() {
        assert!(!in_session(ny("2026-11-02 09:30"))); // no bar has closed yet
        assert!(in_session(ny("2026-11-02 09:31")));
        assert!(in_session(ny("2026-11-02 16:10")));
        assert!(!in_session(ny("2026-11-02 16:11")));
        assert!(!in_session(ny("2026-11-07 11:00"))); // Saturday
                                                      // Day after Thanksgiving closes at 13:00.
        assert!(!in_session(ny("2026-11-27 13:30")));
    }

    #[test]
    fn a_key_is_due_once_its_next_bar_can_have_closed() {
        let newest = ny("2026-11-02 10:00");
        let cursor = Cursor {
            newest,
            quiet_until: None,
        };
        // The 10:01 bar closes at 10:02.
        assert!(!is_due(&cursor, Granularity::M1, ny("2026-11-02 10:01")));
        assert!(is_due(&cursor, Granularity::M1, ny("2026-11-02 10:02")));
        // The 10:05 five-minute bar closes at 10:10.
        assert!(!is_due(&cursor, Granularity::M5, ny("2026-11-02 10:09")));
        assert!(is_due(&cursor, Granularity::M5, ny("2026-11-02 10:10")));

        let quiet = Cursor {
            newest,
            quiet_until: Some(ny("2026-11-02 10:30")),
        };
        assert!(!is_due(&quiet, Granularity::M1, ny("2026-11-02 10:20")));
    }

    #[test]
    fn the_window_starts_after_the_newest_bar_and_never_reaches_far_back() {
        let now = ny("2026-11-02 10:10");
        let cursor = Cursor {
            newest: ny("2026-11-02 10:00"),
            quiet_until: None,
        };
        assert_eq!(
            window(&cursor, Granularity::M1, now),
            (ny("2026-11-02 10:01"), now)
        );

        let stale = Cursor {
            newest: ny("2026-10-01 10:00"),
            quiet_until: None,
        };
        assert_eq!(window(&stale, Granularity::M1, now).0, now - MAX_WINDOW);
    }

    #[test]
    fn polls_a_few_seconds_past_each_minute() {
        let at = |s: u32| ny("2026-11-02 10:00") + Duration::seconds(i64::from(s));
        assert_eq!(until_next_poll(at(0)), std::time::Duration::from_secs(5));
        assert_eq!(until_next_poll(at(5)), std::time::Duration::from_secs(60));
        assert_eq!(until_next_poll(at(30)), std::time::Duration::from_secs(35));
    }
}
