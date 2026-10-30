//! The live engine's Questrade connection, which can be replaced while the
//! engine runs: a fresh token pasted on Opus's Accounts page
//! (`POST /api/questrade/connect`) or the background retry after a failed
//! start swaps a new client in, so getting Questrade back never needs a
//! restart.
//!
//! Refresh tokens are single-use and rotate on every authentication, so
//! connect attempts run one at a time: two at once would spend the same
//! saved token and one would lose.

use std::future::Future;
use std::sync::{Arc, PoisonError, RwLock};
use std::time::Duration;

use sqlx::PgPool;
use tokio::sync::Mutex;

use super::client::{is_token_refused, QuestradeClient};
use crate::error::{AppError, AppResult};

/// A connected client, shared by every route that calls Questrade. Its own
/// Mutex serialises calls, as Questrade's token refresh needs.
pub type SharedClient = Arc<Mutex<QuestradeClient>>;

/// First wait of the background retry after a failed start; it doubles up
/// to `MAX_RETRY_WAIT`.
const FIRST_RETRY_WAIT: Duration = Duration::from_secs(60);
const MAX_RETRY_WAIT: Duration = Duration::from_secs(15 * 60);

/// The slot holding the current client, if any. The slot's lock is a plain
/// `RwLock` held only to read or replace the `Arc`, never across an await.
#[derive(Default)]
pub struct QuestradeLink {
    slot: RwLock<Option<SharedClient>>,
    /// Held for the whole of a connect attempt: one at a time.
    connecting: Mutex<()>,
}

/// What a connect attempt did.
#[derive(Debug, PartialEq, Eq)]
pub enum Connect {
    /// A new client is in the slot.
    Connected,
    /// The attempt had no token to try (no saved token).
    NoToken,
    /// `connect_if_disconnected` found a client already there.
    AlreadyConnected,
}

impl QuestradeLink {
    /// A link holding `client`, or nothing.
    pub fn new(client: Option<QuestradeClient>) -> Self {
        Self {
            slot: RwLock::new(client.map(|c| Arc::new(Mutex::new(c)))),
            connecting: Mutex::new(()),
        }
    }

    /// The current client, if one is connected.
    pub fn client(&self) -> Option<SharedClient> {
        self.slot
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    pub fn is_connected(&self) -> bool {
        self.client().is_some()
    }

    /// Run `attempt` and, when it yields a client, swap it in. A failed
    /// attempt leaves the slot as it was. Refused with `Conflict` while
    /// another attempt is running.
    pub async fn connect<F>(&self, attempt: F) -> AppResult<Connect>
    where
        F: Future<Output = AppResult<Option<QuestradeClient>>>,
    {
        self.swap_in(attempt, false).await
    }

    /// `connect`, but only when no client is in the slot (checked inside the
    /// one-at-a-time section, so a connect that just finished is seen).
    pub async fn connect_if_disconnected<F>(&self, attempt: F) -> AppResult<Connect>
    where
        F: Future<Output = AppResult<Option<QuestradeClient>>>,
    {
        self.swap_in(attempt, true).await
    }

    async fn swap_in<F>(&self, attempt: F, only_if_empty: bool) -> AppResult<Connect>
    where
        F: Future<Output = AppResult<Option<QuestradeClient>>>,
    {
        let _one_at_a_time = self.connecting.try_lock().map_err(|_| {
            AppError::Conflict(
                "A Questrade connect is already running; try again in a moment.".into(),
            )
        })?;

        let current = self.client();
        if only_if_empty && current.is_some() {
            return Ok(Connect::AlreadyConnected);
        }
        // Hold the current client while the attempt runs, so none of its
        // requests re-authenticates with the same saved token meanwhile.
        let _current_held = match &current {
            Some(client) => Some(client.lock().await),
            None => None,
        };

        match attempt.await? {
            Some(client) => {
                *self.slot.write().unwrap_or_else(PoisonError::into_inner) =
                    Some(Arc::new(Mutex::new(client)));
                Ok(Connect::Connected)
            }
            None => Ok(Connect::NoToken),
        }
    }
}

/// After a failed start: retry the saved token with backoff until Questrade
/// is connected (by this loop or by a pasted token), then stop. Each success
/// rotates the token, so nothing retries once connected. A start with no
/// token at all doesn't run this, and a token Questrade refuses stops it:
/// it won't become good again, so the Accounts page form is the way in.
pub async fn retry_until_connected(link: Arc<QuestradeLink>, pool: PgPool) {
    let mut wait = FIRST_RETRY_WAIT;
    loop {
        tokio::time::sleep(wait).await;
        match link
            .connect_if_disconnected(QuestradeClient::connect(&pool, None))
            .await
        {
            Ok(Connect::Connected) => {
                tracing::info!("Questrade reconnected with the saved token.");
                return;
            }
            Ok(Connect::AlreadyConnected) => return,
            Ok(Connect::NoToken) => {
                tracing::info!(
                    "No saved Questrade token to retry; paste a new one on the Accounts page."
                );
                return;
            }
            Err(AppError::Conflict(_)) => {}
            Err(e) if is_token_refused(&e) => {
                tracing::warn!(
                    "Questrade refused the saved token ({e}); stopped retrying. \
                     Paste a new one on the Accounts page."
                );
                return;
            }
            Err(e) => {
                wait = next_wait(wait);
                tracing::warn!("Questrade reconnect failed: {e}. Next try in {wait:?}.");
            }
        }
    }
}

fn next_wait(wait: Duration) -> Duration {
    (wait * 2).min(MAX_RETRY_WAIT)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pool() -> PgPool {
        sqlx::postgres::PgPoolOptions::new()
            .connect_lazy("postgres://test:test@localhost/test")
            .expect("lazy pool should build")
    }

    fn client() -> QuestradeClient {
        QuestradeClient::new(&pool(), "token".into()).unwrap()
    }

    #[tokio::test]
    async fn a_new_client_is_swapped_in() {
        let link = QuestradeLink::new(None);
        assert!(!link.is_connected());
        let result = link.connect(async { Ok(Some(client())) }).await.unwrap();
        assert_eq!(result, Connect::Connected);
        assert!(link.is_connected());
    }

    #[tokio::test]
    async fn a_failed_attempt_leaves_the_slot_as_it_was() {
        let link = QuestradeLink::new(Some(client()));
        let before = link.client().unwrap();
        let result = link
            .connect(async { Err(AppError::Internal("rejected".into())) })
            .await;
        assert!(result.is_err());
        assert!(Arc::ptr_eq(&before, &link.client().unwrap()));

        let empty = QuestradeLink::new(None);
        let result = empty
            .connect(async { Err(AppError::Internal("rejected".into())) })
            .await;
        assert!(result.is_err());
        assert!(!empty.is_connected());
    }

    #[tokio::test]
    async fn no_token_changes_nothing() {
        let link = QuestradeLink::new(None);
        assert_eq!(
            link.connect(async { Ok(None) }).await.unwrap(),
            Connect::NoToken
        );
        assert!(!link.is_connected());
    }

    #[tokio::test]
    async fn a_pasted_token_replaces_a_connected_client() {
        let link = QuestradeLink::new(Some(client()));
        let before = link.client().unwrap();
        link.connect(async { Ok(Some(client())) }).await.unwrap();
        assert!(!Arc::ptr_eq(&before, &link.client().unwrap()));
    }

    #[tokio::test]
    async fn the_retry_never_runs_its_attempt_while_connected() {
        let link = QuestradeLink::new(Some(client()));
        let result = link
            .connect_if_disconnected(async { panic!("must not try a token while connected") })
            .await
            .unwrap();
        assert_eq!(result, Connect::AlreadyConnected);
    }

    #[tokio::test]
    async fn only_one_attempt_runs_at_a_time() {
        let link = Arc::new(QuestradeLink::new(None));
        let (started_tx, started) = tokio::sync::oneshot::channel::<()>();
        let (release, wait) = tokio::sync::oneshot::channel::<()>();
        let first = {
            let link = link.clone();
            tokio::spawn(async move {
                link.connect(async {
                    started_tx.send(()).unwrap();
                    wait.await.unwrap();
                    Ok(Some(client()))
                })
                .await
            })
        };
        // The first attempt is running, so it holds the one-at-a-time lock.
        started.await.unwrap();

        let second = link
            .connect(async { panic!("must not run beside another attempt") })
            .await;
        assert!(matches!(second, Err(AppError::Conflict(_))));

        release.send(()).unwrap();
        assert_eq!(first.await.unwrap().unwrap(), Connect::Connected);
    }

    #[test]
    fn the_retry_backs_off_to_fifteen_minutes() {
        let mut wait = FIRST_RETRY_WAIT;
        for _ in 0..10 {
            wait = next_wait(wait);
        }
        assert_eq!(wait, MAX_RETRY_WAIT);
        assert_eq!(next_wait(FIRST_RETRY_WAIT), Duration::from_secs(120));
    }
}
