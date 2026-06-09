use crate::brokers::BrokerStatus;

/// Minimum contract every broker client must satisfy.
/// Each concrete client (OandaClient, QuestradeClient, WealthsimpleClient)
/// implements this trait so the brokers API handler can call them uniformly.
#[allow(async_fn_in_trait)]
pub trait BrokerClient {
    async fn broker_status(&mut self) -> BrokerStatus;
}
