pub mod account_cache;
pub mod candle_feed;
pub mod evaluator;
pub mod instrument_cache;
pub mod position_sync;
pub mod prefill;
pub mod pricing;
pub mod quotes;
pub mod sizing;
pub mod stock_feed;
pub mod trade_management;

use std::future::Future;
use std::time::Duration;

pub(crate) use evaluator::evaluate_and_apply;
pub use pricing::{format_price, format_price_with_precision};

/// Pause before a stopped background task starts again.
const RESTART_AFTER: Duration = Duration::from_secs(5);

/// Run a long-lived background task (the candle feed, the price stream, the
/// quote tracker…) and start it again if it ever stops: a panic inside one
/// would otherwise end it silently while the process, and its health
/// endpoint, look alive. `make` builds a fresh run each time.
pub(crate) fn spawn_supervised<F, Fut>(name: &'static str, make: F)
where
    F: Fn() -> Fut + Send + 'static,
    Fut: Future<Output = ()> + Send + 'static,
{
    tokio::spawn(async move {
        loop {
            match tokio::spawn(make()).await {
                Ok(()) => tracing::error!("[SUPERVISOR] {name} stopped; starting it again"),
                Err(e) if e.is_panic() => {
                    tracing::error!("[SUPERVISOR] {name} panicked; starting it again: {e}")
                }
                Err(e) => tracing::error!("[SUPERVISOR] {name} ended: {e}; starting it again"),
            }
            tokio::time::sleep(RESTART_AFTER).await;
        }
    });
}
