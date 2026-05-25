use sqlx::PgPool;

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct InstrumentRiskParamsRow {
    pub trailing_k: f64,
    pub atr_period: i32,
    pub atr_granularity: String,
    pub exit_confirm_bars: i32,
}

pub(crate) async fn find_instrument_risk_params(
    pool: &PgPool,
    instrument: &str,
    strategy_type: &str,
    granularity: &str,
) -> Result<Option<InstrumentRiskParamsRow>, sqlx::Error> {
    sqlx::query_as!(
        InstrumentRiskParamsRow,
        r#"SELECT trailing_k, atr_period, atr_granularity, exit_confirm_bars
           FROM instrument_risk_params
           WHERE instrument = $1 AND strategy_type = $2 AND granularity = $3"#,
        instrument,
        strategy_type,
        granularity,
    )
    .fetch_optional(pool)
    .await
}
