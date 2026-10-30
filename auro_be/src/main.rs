//! The live engine: OANDA stream, candle feed, evaluator, trade management.
//! Backtests and pipeline stages run in `auro-tester` (src/bin/auro-tester.rs).

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    auro::run(auro::config::Mode::Live).await
}
