//! The tester: backtests, pipeline stages, reports and the Together replay,
//! in their own process so testing never slows live trading. No OANDA
//! stream, no evaluator, no candle polling, no orders.

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    auro::run(auro::config::Mode::Tester).await
}
