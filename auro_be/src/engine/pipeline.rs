use std::collections::BTreeSet;

use chrono::{DateTime, Utc};
use rand::RngExt;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::db::repositories::candles::load_candles;
use crate::db::repositories::financing as financing_repo;
use crate::db::repositories::live_strategies as live_strategies_repo;
use crate::db::repositories::pipeline as pipeline_repo;
use crate::engine::buy_and_hold::{self, Hold};
use crate::engine::financing::{apply_costs, FinancingModel, Overnight};
use crate::engine::stats::{
    backtest_on_account, calculate_backtest_stats, AccountSizing, BacktestStats,
};
use crate::engine::strategy::{self as strategy_mod, SizingConfig, Strategy};
use crate::engine::types::{Candle, Granularity, Trade};
use crate::error::{AppError, AppResult};

pub(crate) mod basket;
mod deflated_sharpe;
mod parameter_stability;

/// The version of the rules the pipeline judges by, saved with every stage
/// result (`strategy_evaluations.rules_version`). Opus reads a result with
/// a lower version, or none, as old: judged by earlier rules, so it has to
/// be re-tested before it counts.
///
/// Bump it whenever a change can turn a past pass into a fail or vice
/// versa (a threshold, a metric's definition, how a stage tests, a stage
/// added or removed), then run `UPDATE_RULES_VERSION=1 cargo test
/// rules_version` to rewrite `opus/priv/rules_version.json`, and add a line
/// below.
///
/// - none (NULL): judged before results were stamped, Oct 30 2026 or earlier.
/// - 1: the rules as of Oct 30 2026: drawdowns valued daily on the account;
///   Monte Carlo redraws the account's daily returns in blocks
///   (`daily_block_bootstrap`) with the 10% account gate; the luck check
///   counts each market's k settings tries as √k; ranked baskets judged on
///   months; the walk-forward's in-sample minimum; the nearby-settings
///   (parameter stability) stage.
/// - 2: Oct 30 2026: shares held outright (`owned_shares`, Wealthsimple)
///   are judged in Monte Carlo against just holding the same funds (bad
///   run at holding's risk no worse than holding's worst drop, Sharpe at
///   least holding's) instead of the fixed 10% cap; CFDs unchanged.
///   Same day (before any v2 pass): the bad run is read against holding's
///   own 1-in-20 bad run, redrawn the same way, not its one actual drop.
/// - 3: Oct 31 2026: the annual Sharpe (the holdout's bar among others) is
///   read from the account valued every day, not each trade booked on the
///   day it closes; Monte Carlo redraws each day with its low, so a dip
///   inside a day counts in its drawdowns as in the backtest's; a basket's
///   walk-forward unseen part warms up on the bars before it (a ranking
///   rebalancing from the split), as the holdout does.
pub const RULES_VERSION: i32 = 3;

#[derive(Clone)]
pub struct StrategyConfig {
    pub id: Uuid,
    pub instrument: String,
    pub granularity: Granularity,
    pub strategy_type: String,
    pub parameters: Value,
}

pub struct EvaluationResult {
    pub evaluation_id: Uuid,
    pub status: String,
    pub stats: Value,
    pub failure_reason: Option<String>,
}

pub(crate) struct ThresholdRow {
    metric: String,
    operator: String,
    value: f64,
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// What kind of market an OANDA instrument is: it sets financing, daily bar
/// alignment and which validation thresholds apply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstrumentClass {
    FxMajor,
    FxCross,
    Metal,
    Commodity,
    Index,
    Bond,
}

impl InstrumentClass {
    /// The name `validation_thresholds.instrument_class` uses.
    pub fn as_str(self) -> &'static str {
        match self {
            InstrumentClass::FxMajor => "fx_major",
            InstrumentClass::FxCross => "fx_cross",
            InstrumentClass::Metal => "metal",
            InstrumentClass::Commodity => "commodity",
            InstrumentClass::Index => "index",
            InstrumentClass::Bond => "bond",
        }
    }
}

/// The class of an OANDA instrument; any pair not listed is an FX cross.
pub fn instrument_class(instrument: &str) -> InstrumentClass {
    match instrument {
        "EUR_USD" | "GBP_USD" | "USD_JPY" | "USD_CHF" | "USD_CAD" | "AUD_USD" | "NZD_USD" => {
            InstrumentClass::FxMajor
        }
        "XAU_USD" | "XAG_USD" | "XPT_USD" | "XPD_USD" | "XCU_USD" => InstrumentClass::Metal,
        "WTICO_USD" | "BCO_USD" | "NATGAS_USD" | "CORN_USD" | "WHEAT_USD" | "SOYBN_USD"
        | "SUGAR_USD" => InstrumentClass::Commodity,
        "UK100_GBP" | "EU50_EUR" | "DE30_EUR" | "FR40_EUR" | "NL25_EUR" | "CH20_CHF"
        | "AU200_AUD" | "JP225_USD" | "HK33_HKD" | "CN50_USD" | "SG30_SGD" | "US30_USD"
        | "SPX500_USD" | "NAS100_USD" | "US2000_USD" => InstrumentClass::Index,
        "USB02Y_USD" | "USB10Y_USD" | "USB30Y_USD" | "DE10YB_EUR" | "UK10YB_GBP" => {
            InstrumentClass::Bond
        }
        _ => InstrumentClass::FxCross,
    }
}

/// The class's threshold name (`InstrumentClass::as_str`).
pub fn instrument_to_class(instrument: &str) -> &'static str {
    instrument_class(instrument).as_str()
}

/// Run CPU-bound backtest work on the blocking pool: on the async runtime it
/// would starve the live price stream and candle feed that share it.
async fn off_runtime<T, F>(work: F) -> AppResult<T>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(work)
        .await
        .map_err(|e| AppError::Internal(format!("backtest task failed: {e}")))
}

/// A strategy read for backtesting: parsed, with its `Carry` blocks given
/// the financing model's policy rates (the same table live reads).
fn parse_strategy(parameters: &Value, financing: &FinancingModel) -> Result<Strategy, String> {
    let mut strategy: Strategy =
        serde_json::from_value(parameters.clone()).map_err(|e| e.to_string())?;
    strategy.attach_policy_rates(financing.policy_rates())?;
    Ok(strategy)
}

pub(crate) fn run_strategy(
    candles: &[Candle],
    config: &StrategyConfig,
    financing: &FinancingModel,
) -> AppResult<Vec<Trade>> {
    // All strategies use the composite shape. Pre-composite flat-shape strategies
    // were purged with the DB wipe; see [[decision-canonical-strategy-shape]].
    // A broker that can't short (Wealthsimple) tests the long side only.
    let parameters = if financing.can_short(&config.instrument) {
        config.parameters.clone()
    } else {
        long_only(&config.parameters)
    };
    let strategy = parse_strategy(&parameters, financing).map_err(|e| {
        AppError::BadRequest(format!(
            "invalid composite strategy parameters for strategy_type={}: {}",
            config.strategy_type, e
        ))
    })?;

    // A warmup the live buffer can't hold means the strategy is dead live —
    // fail loudly here instead of silently producing zero trades.
    let warmup = strategy.warmup();
    let capacity = strategy.granularity.buffer_capacity();
    if warmup + 1 > capacity {
        return Err(AppError::BadRequest(format!(
            "warmup {} exceeds live buffer capacity {} for {} — strategy could never trade live",
            warmup, capacity, strategy.granularity
        )));
    }

    let mut trades = strategy_mod::run_backtest(candles, &strategy);
    apply_costs(&mut trades, &config.instrument, financing);
    Ok(trades)
}

/// The strategy JSON without its short entry rule, for a broker that can't
/// short: it never opens a short, so its short exit rule never fires.
pub(crate) fn long_only(parameters: &Value) -> Value {
    let mut out = parameters.clone();
    if let Some(Value::Object(entry)) = out.get_mut("entry") {
        entry.remove("short");
    }
    out
}

/// Whether `parameters` has a short entry rule its broker skipped.
pub(crate) fn shorts_skipped(parameters: &Value, market: &str, financing: &FinancingModel) -> bool {
    !financing.can_short(market) && parameters.pointer("/entry/short").is_some()
}

/// The costs a one-market test charged, for the results page: its broker,
/// what holding overnight cost, the spread and commission per trade (a
/// null spread: the bars' own bid/ask), and whether its short rules were
/// skipped. None for a basket, whose markets each have their own.
fn costs_json(config: &StrategyConfig, financing: &FinancingModel) -> Option<Value> {
    if config.parameters.get("basket").is_some() {
        return None;
    }
    let costs = financing.costs_for(&config.instrument)?;
    Some(serde_json::json!({
        "broker": costs.broker,
        "overnight": match costs.overnight {
            Overnight::OandaFinancing => "oanda_financing",
            Overnight::None => "none",
        },
        "spread_bps": costs.spread_bps,
        "commission_bps": costs.commission_bps,
        "shorts_skipped": shorts_skipped(&config.parameters, &config.instrument, financing),
        // Shares held outright: their dividends are paid to longs, known
        // from this ex-date ("none" when the fund pays none).
        "dividends_from": match (costs.overnight, financing.dividends_from(&config.instrument)) {
            (Overnight::None, Some(Some(first))) => serde_json::json!(first),
            (Overnight::None, Some(None)) => serde_json::json!("none"),
            _ => Value::Null,
        },
        // No dividend history to fetch (Massive is US only): the test runs
        // without the dividends before the first one recorded ("none" when
        // none has been yet).
        "dividends_recorded_since": match (
            costs.overnight,
            financing.dividends_recorded_since(&config.instrument),
        ) {
            (Overnight::None, Some(Some(first))) => serde_json::json!(first),
            (Overnight::None, Some(None)) => serde_json::json!("none"),
            _ => Value::Null,
        },
    }))
}

/// How `config`'s strategy sizes its trades, for the account figures.
pub(crate) fn account_sizing(config: &StrategyConfig) -> AppResult<AccountSizing> {
    let sizing: SizingConfig = serde_json::from_value(
        config
            .parameters
            .get("sizing")
            .cloned()
            .unwrap_or(Value::Null),
    )
    .map_err(|e| AppError::BadRequest(format!("invalid strategy sizing: {e}")))?;
    Ok(AccountSizing::of(&sizing))
}

pub fn run_backtest_stats(
    candles: &[Candle],
    config: &StrategyConfig,
    active_start_idx: Option<usize>,
    financing: &FinancingModel,
) -> AppResult<BacktestStats> {
    let sizing = account_sizing(config)?;
    if candles.is_empty() {
        return Ok(calculate_backtest_stats(&[], candles, sizing));
    }

    if let Some(idx) = active_start_idx {
        if idx >= candles.len() {
            return Err(AppError::BadRequest(format!(
                "active_start_idx {} out of range for {} candles",
                idx,
                candles.len()
            )));
        }
    }

    let trades = run_strategy(candles, config, financing)?;

    match active_start_idx {
        None | Some(0) => Ok(calculate_backtest_stats(&trades, candles, sizing)),
        Some(idx) => {
            let active_start_time = candles[idx].time;
            let filtered: Vec<Trade> = trades
                .into_iter()
                .filter(|t| t.entry_time >= active_start_time)
                .collect();
            Ok(calculate_backtest_stats(&filtered, &candles[idx..], sizing))
        }
    }
}

/// Overnight financing model for a stage's backtests (one DB read per stage).
pub(crate) async fn load_financing(pool: &PgPool) -> AppResult<FinancingModel> {
    financing_repo::load_model(pool)
        .await
        .map_err(|e| AppError::Internal(format!("load financing model: {e}")))
}

/// The stretch `candles` cover, first bar to last, for the annual Sharpe.
/// An empty slice is an empty stretch.
pub(crate) fn span(candles: &[Candle]) -> (DateTime<Utc>, DateTime<Utc>) {
    match (candles.first(), candles.last()) {
        (Some(first), Some(last)) => (first.time, last.time),
        _ => (Utc::now(), Utc::now()),
    }
}

/// How many standard errors the average trade sits above zero: the
/// per-trade Sharpe (mean / spread of trade returns) times √trades. Around
/// 2 or more means a result this good would rarely come from luck alone.
/// For a ranked basket the Sharpe and the count are its months'
/// (`BacktestStats::judge_by_months`).
pub(crate) fn t_stat(stats: &BacktestStats) -> f64 {
    stats.sharpe_ratio * (stats.periods() as f64).sqrt()
}

fn compute_expectancy(stats: &BacktestStats) -> f64 {
    let loss_rate = 1.0 - stats.win_rate;
    (stats.win_rate * stats.avg_win) - (loss_rate * stats.avg_loss.abs())
}

fn apply_threshold(operator: &str, actual: f64, threshold: f64) -> bool {
    match operator {
        "gte" => actual >= threshold,
        "lte" => actual <= threshold,
        "gt" => actual > threshold,
        "lt" => actual < threshold,
        _ => false,
    }
}

fn operator_failure_text(operator: &str) -> &'static str {
    match operator {
        "gte" => "is below minimum",
        "gt" => "must be greater than",
        "lte" => "is above maximum",
        "lt" => "must be less than",
        _ => "does not satisfy",
    }
}

/// Judge stage stats against the thresholds, and record every check in
/// `stats_json["checks"]` (`metric`, `operator`, `required`, `actual`,
/// `passed`) so a page can show each rule next to its result.
pub(crate) fn evaluate_thresholds(
    stats_json: &mut Value,
    thresholds: &[ThresholdRow],
    stage: &str,
    timeframe_class: &str,
) -> (String, Option<String>) {
    if thresholds.is_empty() {
        return (
            "failed".to_string(),
            Some(format!(
                "no thresholds configured for stage={} timeframe_class={}",
                stage, timeframe_class
            )),
        );
    }

    let checks: Vec<(&ThresholdRow, Option<f64>, bool)> = thresholds
        .iter()
        .map(|t| {
            let actual = stats_json.get(&t.metric).and_then(|v| v.as_f64());
            let passed = actual.is_some_and(|a| apply_threshold(&t.operator, a, t.value));
            (t, actual, passed)
        })
        .collect();

    let failures: Vec<String> = checks
        .iter()
        .filter(|(_, _, passed)| !passed)
        .map(|(t, actual, _)| match actual {
            None => format!("{}: missing from stats", t.metric),
            Some(a) => format!(
                "{}: {:.4} {} {:.4}",
                t.metric,
                a,
                operator_failure_text(&t.operator),
                t.value
            ),
        })
        .collect();

    stats_json["checks"] = Value::Array(
        checks
            .iter()
            .map(|(t, actual, passed)| {
                serde_json::json!({
                    "metric": t.metric,
                    "operator": t.operator,
                    "required": t.value,
                    "actual": actual,
                    "passed": passed,
                })
            })
            .collect(),
    );

    if failures.is_empty() {
        ("passed".to_string(), None)
    } else {
        ("failed".to_string(), Some(failures.join("; ")))
    }
}

// ---------------------------------------------------------------------------
// DB helpers
// ---------------------------------------------------------------------------

/// Refuse a test on a market with no broker set (`instruments.test_broker`):
/// without one there are no costs to grade it on, and OANDA's are not a
/// stand-in for anyone else's. Checked before a stage writes anything, so
/// a refused test leaves no result behind.
pub async fn require_brokers(pool: &PgPool, config: &StrategyConfig) -> AppResult<()> {
    let markets = match basket::Basket::of(config) {
        Ok(Some(basket)) => basket.markets,
        _ => vec![config.instrument.clone()],
    };
    let financing = load_financing(pool).await?;
    let off: Vec<&str> = markets
        .iter()
        .filter(|m| financing.costs_for(m).is_none())
        .map(String::as_str)
        .collect();
    if !off.is_empty() {
        return Err(AppError::BadRequest(format!(
            "{} {} no broker set for {} tests (the Instruments page), so there are no costs \
             to grade {} on.",
            off.join(", "),
            if off.len() == 1 { "has" } else { "have" },
            if off.len() == 1 { "its" } else { "their" },
            if off.len() == 1 { "it" } else { "them" }
        )));
    }
    // Shares held outright earn their dividends: unknown ones would leave
    // a long hold's income out of its grade. A market with no history to
    // fetch (Massive is US only) is tested without it, and its results say
    // so (`dividends_recorded_since`).
    let unknown: Vec<&str> = markets
        .iter()
        .filter(|m| {
            financing.owns_shares(m)
                && financing.dividends_from(m).is_none()
                && financing.dividends_recorded_since(m).is_none()
        })
        .map(String::as_str)
        .collect();
    if unknown.is_empty() {
        return Ok(());
    }
    Err(AppError::BadRequest(format!(
        "{}'s dividends haven't been loaded, so a long hold would be graded without its \
         income. Load them first (Load dividends, on the Instruments page).",
        unknown.join(", ")
    )))
}

pub async fn load_strategy_config(pool: &PgPool, config_id: Uuid) -> AppResult<StrategyConfig> {
    let row = pipeline_repo::find_strategy_config(pool, config_id)
        .await
        .map_err(AppError::Database)?
        .ok_or_else(|| AppError::NotFound(format!("strategy_config {}", config_id)))?;

    let granularity: Granularity = row
        .granularity
        .parse()
        .map_err(|e| AppError::BadRequest(format!("invalid granularity: {}", e)))?;

    Ok(StrategyConfig {
        id: config_id,
        instrument: row.instrument,
        granularity,
        strategy_type: row.strategy_type,
        parameters: row.parameters,
    })
}

pub(crate) async fn load_thresholds(
    pool: &PgPool,
    stage: &str,
    timeframe_class: &str,
    instrument_class: &str,
    strategy_type: &str,
) -> AppResult<Vec<ThresholdRow>> {
    let rows = pipeline_repo::load_validation_thresholds(
        pool,
        stage,
        timeframe_class,
        instrument_class,
        strategy_type,
    )
    .await
    .map_err(AppError::Database)?;

    Ok(rows
        .into_iter()
        .map(|row| ThresholdRow {
            metric: row.metric,
            operator: row.operator,
            value: row.value,
        })
        .collect())
}

async fn upsert_evaluation_running(pool: &PgPool, config_id: Uuid, stage: &str) -> AppResult<Uuid> {
    pipeline_repo::upsert_evaluation_running(pool, config_id, stage)
        .await
        .map_err(AppError::Database)
}

async fn finalize_evaluation(
    pool: &PgPool,
    evaluation_id: Uuid,
    status: &str,
    stats: &Value,
    failure_reason: Option<&str>,
) -> AppResult<()> {
    pipeline_repo::finalize_evaluation(
        pool,
        evaluation_id,
        status,
        stats,
        failure_reason,
        RULES_VERSION,
    )
    .await
    .map_err(AppError::Database)
}

async fn fail_stage(
    pool: &PgPool,
    evaluation_id: Uuid,
    failure: String,
) -> AppResult<EvaluationResult> {
    let stats = serde_json::json!({});
    finalize_evaluation(pool, evaluation_id, "failed", &stats, Some(&failure)).await?;
    Ok(EvaluationResult {
        evaluation_id,
        status: "failed".to_string(),
        stats,
        failure_reason: Some(failure),
    })
}

// ---------------------------------------------------------------------------
// Sealed holdout
// ---------------------------------------------------------------------------

/// Start of the sealed holdout window: `trading_config.pipeline_holdout_start`,
/// an ISO date. The exploration stages (backtest, walk-forward, Monte Carlo)
/// never see bars from it onward; the holdout stage alone does, once per
/// config. A missing or malformed value is an error rather than "no holdout":
/// the pipeline must not run unsealed by accident.
pub async fn load_holdout_start(pool: &PgPool) -> AppResult<chrono::DateTime<chrono::Utc>> {
    let rows = live_strategies_repo::list_trading_config(pool)
        .await
        .map_err(AppError::Database)?;
    let raw = rows
        .iter()
        .find(|r| r.key == "pipeline_holdout_start")
        .and_then(|r| r.value.as_str().map(str::to_string))
        .ok_or_else(|| {
            AppError::Internal(
                "trading_config.pipeline_holdout_start is not set; refusing to run the pipeline unsealed"
                    .into(),
            )
        })?;
    let date = chrono::NaiveDate::parse_from_str(&raw, "%Y-%m-%d").map_err(|e| {
        AppError::Internal(format!(
            "pipeline_holdout_start {raw:?} is not an ISO date: {e}"
        ))
    })?;
    Ok(chrono::DateTime::from_naive_utc_and_offset(
        date.and_hms_opt(0, 0, 0).expect("midnight exists"),
        chrono::Utc,
    ))
}

/// `candles` from the first ex-date on record when `market` is shares held
/// outright: before it the dividends are unknown, so a long hold there
/// would be graded without its income. Other markets' bars are unchanged.
fn from_known_dividends(
    candles: Vec<Candle>,
    market: &str,
    financing: &FinancingModel,
) -> Vec<Candle> {
    match (
        financing.owns_shares(market),
        financing.dividends_from(market),
    ) {
        (true, Some(Some(first))) => candles
            .into_iter()
            .filter(|c| {
                c.time
                    .with_timezone(&chrono_tz::America::New_York)
                    .date_naive()
                    >= first
            })
            .collect(),
        _ => candles,
    }
}

/// The bars an exploration stage may see: everything before the holdout.
pub(crate) async fn load_exploration_candles(
    pool: &PgPool,
    config: &StrategyConfig,
) -> AppResult<Vec<Candle>> {
    let holdout_start = load_holdout_start(pool).await?;
    let candles = load_candles(pool, &config.instrument, config.granularity)
        .await
        .map_err(AppError::Database)?;
    Ok(candles
        .into_iter()
        .filter(|c| c.time < holdout_start)
        .collect())
}

/// What a stage tests: one market's bars, or a basket's
/// (`basket` module).
pub(crate) enum Subject {
    One(Vec<Candle>),
    Basket(basket::Basket, Vec<basket::Member>),
}

/// The stretch of history a run uses.
#[derive(Debug, Clone, Copy)]
enum Part {
    Whole,
    /// The walk-forward's first 70%.
    InSample,
    /// Its last 30%.
    OutOfSample,
    /// Every bar, counting only trades entered from this moment on.
    Holdout(DateTime<Utc>),
}

/// A run's figures: its stats, the returns it's judged on (the luck check
/// reads their shape), the account's daily returns (Monte Carlo redraws
/// them) and, for a basket, its part of the stats for the results page
/// (`basket::stats_json`).
struct Tested {
    stats: BacktestStats,
    /// Each trade's return (for a together basket, what it did to the
    /// account), or for a ranked basket each calendar month's account
    /// return (`basket::Run::returns`).
    returns: Vec<f64>,
    /// The account's return each trading day, valued at the day's last
    /// bar (`Outcome::daily_valued`), and its lowest value in the day
    /// (`Outcome::daily_lows`).
    daily: Vec<f64>,
    lows: Vec<f64>,
    basket: Option<Value>,
}

/// What `config` tests: the bars before the holdout when `sealed`, else
/// all of them. `Ok(Err(words))` is a config that can't be tested, said
/// plainly: its basket settings are wrong, or a market in it has no bars.
async fn load_subject(
    pool: &PgPool,
    config: &StrategyConfig,
    sealed: bool,
) -> AppResult<Result<Subject, String>> {
    let basket = match basket::Basket::of(config) {
        Ok(basket) => basket,
        Err(words) => return Ok(Err(words)),
    };
    let Some(basket) = basket else {
        let candles = if sealed {
            load_exploration_candles(pool, config).await?
        } else {
            load_candles(pool, &config.instrument, config.granularity)
                .await
                .map_err(AppError::Database)?
        };
        let financing = load_financing(pool).await?;
        return Ok(Ok(Subject::One(from_known_dividends(
            candles,
            &config.instrument,
            &financing,
        ))));
    };
    let before = match sealed {
        true => Some(load_holdout_start(pool).await?),
        false => None,
    };
    let mut members = basket::load(pool, &basket, config.granularity, before).await?;
    // Each fund from its first known dividend, as on its own.
    let financing = load_financing(pool).await?;
    for member in &mut members {
        let candles = std::mem::take(&mut member.candles);
        member.candles = from_known_dividends(candles, &member.market, &financing);
    }
    if let Some(missing) = basket::missing(&members, |_| true) {
        return Ok(Err(format!(
            "No {} bars{} for {}: take {} out of the basket",
            config.granularity,
            if sealed {
                " from before the holdout"
            } else {
                ""
            },
            missing.join(", "),
            if missing.len() == 1 { "it" } else { "them" }
        )));
    }
    Ok(Ok(Subject::Basket(basket, members)))
}

impl Subject {
    /// Just holding the same funds over the same bars
    /// (`buy_and_hold::hold`), for a result on shares held outright: the
    /// benchmark a long-only rule there has to beat. None for anything
    /// else (a CFD held long pays financing, so holding isn't free).
    fn hold(&self, instrument: &str, financing: &FinancingModel) -> Option<Hold> {
        let funds: Vec<(&str, &[Candle])> = match self {
            Subject::One(candles) => vec![(instrument, candles.as_slice())],
            Subject::Basket(_, members) => members
                .iter()
                .map(|m| (m.market.as_str(), m.candles.as_slice()))
                .collect(),
        };
        if !funds
            .iter()
            .all(|(market, _)| financing.owns_shares(market))
        {
            return None;
        }
        let with_dividends: Vec<buy_and_hold::Fund> = funds
            .iter()
            .map(|(market, candles)| (*candles, financing.dividends(market)))
            .collect();
        buy_and_hold::hold(&with_dividends)
    }

    /// One market's bars; None for a basket.
    fn single(&self) -> Option<&[Candle]> {
        match self {
            Subject::One(candles) => Some(candles),
            Subject::Basket(..) => None,
        }
    }

    /// Bars to check a strategy can compute on: the market's, or the
    /// basket's first market's.
    fn probe(&self) -> &[Candle] {
        match self {
            Subject::One(candles) => candles,
            Subject::Basket(_, members) => members.first().map_or(&[], |m| &m.candles),
        }
    }

    /// The basket's markets, for counting holdout looks; None for one market.
    fn basket_markets(&self) -> Option<Vec<String>> {
        match self {
            Subject::One(_) => None,
            Subject::Basket(basket, _) => Some(basket.markets.clone()),
        }
    }

    /// Run `config`'s strategy over `part` and judge-ready figures.
    fn test(
        &self,
        config: &StrategyConfig,
        financing: &FinancingModel,
        part: Part,
    ) -> Result<Tested, String> {
        match self {
            Subject::One(candles) => {
                let split = candles.len() * 7 / 10;
                let bars = match part {
                    Part::Whole | Part::Holdout(_) => &candles[..],
                    Part::InSample => &candles[..split],
                    Part::OutOfSample => &candles[split..],
                };
                let sizing = account_sizing(config).map_err(|e| e.to_string())?;
                let mut trades =
                    run_strategy(bars, config, financing).map_err(|e| e.to_string())?;
                let counted = match part {
                    Part::Holdout(at) => {
                        let first = bars
                            .iter()
                            .position(|c| c.time >= at)
                            .ok_or("no bars in the holdout window")?;
                        trades.retain(|t| t.entry_time >= bars[first].time);
                        &bars[first..]
                    }
                    _ => bars,
                };
                let (stats, outcome) = backtest_on_account(&trades, counted, sizing);
                Ok(Tested {
                    stats,
                    returns: trades.iter().map(|t| t.pnl_percent).collect(),
                    daily: outcome.daily_valued,
                    lows: outcome.daily_lows,
                    basket: None,
                })
            }
            Subject::Basket(basket, members) => {
                let split = || basket::split_at(members).ok_or("no bars to split");
                let window = match part {
                    Part::Whole => basket::Window::Whole,
                    Part::InSample => basket::Window::Before(split()?),
                    // Warmed on the in-sample bars, as the holdout is, so a
                    // ranking's long look-back doesn't eat the unseen part.
                    Part::OutOfSample => basket::Window::Counting(split()?),
                    Part::Holdout(at) => basket::Window::Counting(at),
                };
                let run = basket::run(members, basket, config, financing, window)?;
                let json = basket::stats_json(basket, config.granularity, &run);
                Ok(Tested {
                    returns: run.returns(),
                    daily: run.outcome.daily_valued,
                    lows: run.outcome.daily_lows,
                    stats: run.stats,
                    basket: Some(json),
                })
            }
        }
    }
}

/// The `validation_thresholds.strategy_type` a ranked basket's months
/// minimums are stored under.
const RANKED_BASKET_RULES: &str = "ranked_basket";

/// Each trade-count rule and the months rule a ranked basket is judged on
/// instead: it holds positions across rebalances, so its "trades" are few
/// and long, and the papers judge such books on monthly returns.
const MONTHS_FOR_TRADES: [(&str, &str); 3] = [
    ("num_trades", "num_months"),
    ("is_num_trades", "is_num_months"),
    ("oos_num_trades", "oos_num_months"),
];

/// A ranked basket's rules: `rows` with every trade-count rule swapped for
/// its months rule from `months` (the `ranked_basket` rows), and the months
/// metrics that have no rule yet, which fail the stage rather than pass it
/// unchecked.
fn months_rules(
    rows: Vec<ThresholdRow>,
    months: Vec<ThresholdRow>,
) -> (Vec<ThresholdRow>, Vec<&'static str>) {
    let mut missing = Vec::new();
    let mut out: Vec<ThresholdRow> = Vec::with_capacity(rows.len());
    for row in rows {
        match MONTHS_FOR_TRADES.iter().find(|(t, _)| *t == row.metric) {
            Some((_, month_metric)) => missing.push(*month_metric),
            None => out.push(row),
        }
    }
    for row in months {
        if let Some(i) = missing.iter().position(|m| *m == row.metric) {
            missing.remove(i);
            out.push(row);
        }
    }
    (out, missing)
}

/// Judge a stage's stats against its thresholds, save the verdict and
/// hand it back. A ranked basket is judged on months, not trades
/// (`months_rules`).
/// The class a config's pass bars are chosen by
/// (`validation_thresholds.instrument_class`): `owned_shares` when every
/// market in it is shares held outright (a cash account at Wealthsimple:
/// judged against just holding them), else the OANDA instrument's class.
async fn market_class(pool: &PgPool, config: &StrategyConfig) -> AppResult<&'static str> {
    let markets = match basket::Basket::of(config) {
        Ok(Some(basket)) => basket.markets,
        _ => vec![config.instrument.clone()],
    };
    let financing = load_financing(pool).await?;
    Ok(if markets.iter().all(|m| financing.owns_shares(m)) {
        OWNED_SHARES
    } else {
        instrument_to_class(&config.instrument)
    })
}

/// The pass-bar class of shares held outright (`market_class`).
pub const OWNED_SHARES: &str = "owned_shares";

async fn judge(
    pool: &PgPool,
    config: &StrategyConfig,
    evaluation_id: Uuid,
    stage: &str,
    mut stats_json: Value,
) -> AppResult<EvaluationResult> {
    let timeframe_class = config.granularity.timeframe_class();
    let instrument_class = market_class(pool, config).await?;
    let mut thresholds = load_thresholds(
        pool,
        stage,
        timeframe_class,
        instrument_class,
        &config.strategy_type,
    )
    .await?;
    let ranked = matches!(
        basket::Basket::of(config),
        Ok(Some(b)) if b.mode == basket::Mode::Ranked
    );
    let mut unset: Vec<&str> = Vec::new();
    if ranked {
        let months = load_thresholds(
            pool,
            stage,
            timeframe_class,
            instrument_class,
            RANKED_BASKET_RULES,
        )
        .await?;
        (thresholds, unset) = months_rules(thresholds, months);
    }
    let (mut status, mut failure_reason) =
        evaluate_thresholds(&mut stats_json, &thresholds, stage, timeframe_class);
    if !unset.is_empty() {
        let words = format!(
            "A ranked basket is judged on months of results, not trades, and no months minimum is set up for this test yet ({}). It can't pass until the ranked-basket rules are added",
            unset.join(", ")
        );
        status = "failed".to_string();
        failure_reason = Some(match failure_reason {
            Some(more) => format!("{words}; {more}"),
            None => words,
        });
    }
    finalize_evaluation(
        pool,
        evaluation_id,
        &status,
        &stats_json,
        failure_reason.as_deref(),
    )
    .await?;
    Ok(EvaluationResult {
        evaluation_id,
        status,
        stats: stats_json,
        failure_reason,
    })
}

/// The one look at the sealed window: the strategy runs over full history
/// (so indicators warm up on exploration bars) and only trades entered on or
/// after the holdout start count. `holdout_looks` in the stats is how many
/// sibling candidates (same instrument and strategy type, or the same
/// basket) have been judged on this window, this one included — the more
/// looks, the less a pass means.
pub async fn run_holdout(pool: &PgPool, config: &StrategyConfig) -> AppResult<EvaluationResult> {
    let evaluation_id = upsert_evaluation_running(pool, config.id, "holdout").await?;

    let holdout_start = load_holdout_start(pool).await?;
    let subject = match load_subject(pool, config, false).await? {
        Ok(subject) => subject,
        Err(failure) => return fail_stage(pool, evaluation_id, failure).await,
    };
    let in_window = |c: &Candle| c.time >= holdout_start;
    let gap = match &subject {
        Subject::One(candles) => (!candles.iter().any(in_window)).then(|| {
            format!(
                "no candles in the holdout window for {} {} (from {})",
                config.instrument,
                config.granularity,
                holdout_start.format("%Y-%m-%d")
            )
        }),
        Subject::Basket(_, members) => basket::missing(members, in_window).map(|missing| {
            format!(
                "no bars in the holdout window (from {}) for {}",
                holdout_start.format("%Y-%m-%d"),
                missing.join(", ")
            )
        }),
    };
    if let Some(failure) = gap {
        return fail_stage(pool, evaluation_id, failure).await;
    }
    let basket_markets = subject.basket_markets();

    let financing = load_financing(pool).await?;
    let job = config.clone();
    let tested =
        match off_runtime(move || subject.test(&job, &financing, Part::Holdout(holdout_start)))
            .await?
        {
            Ok(tested) => tested,
            Err(failure) => return fail_stage(pool, evaluation_id, failure).await,
        };
    let looks = pipeline_repo::count_holdout_looks(
        pool,
        &config.instrument,
        &config.strategy_type,
        basket_markets.as_deref(),
    )
    .await
    .map_err(AppError::Database)?;

    let mut stats_json = backtest_stats_to_json(&tested.stats);
    stats_json["holdout_start"] = serde_json::json!(holdout_start.format("%Y-%m-%d").to_string());
    stats_json["holdout_looks"] = serde_json::json!(looks);
    if let Some(extra) = tested.basket {
        stats_json["basket"] = extra;
    }
    let result = judge(pool, config, evaluation_id, "holdout", stats_json).await?;

    tracing::info!(
        config_id = %config.id,
        instrument = %config.instrument,
        granularity = %config.granularity,
        status = %result.status,
        holdout_looks = looks,
        "[Pipeline] holdout stage complete"
    );

    Ok(result)
}

// ---------------------------------------------------------------------------
// Backtest stage
// ---------------------------------------------------------------------------

/// A stage's stats as saved. A ranked basket's also carry `num_months`
/// (the month count its months minimum judges) and `judged_on: "months"`:
/// its Sharpe and `t_stat` are then its months'. Every drawdown is valued
/// at each bar's close, open trades included (`stats::calculate_backtest_stats`).
pub(crate) fn backtest_stats_to_json(stats: &BacktestStats) -> Value {
    let expectancy = compute_expectancy(stats);
    let mut json = serde_json::json!({
        "sharpe":        stats.sharpe_ratio,
        "annual_sharpe": stats.annual_sharpe,
        "t_stat":        t_stat(stats),
        "max_drawdown": stats.max_drawdown.abs(),
        "num_trades":   stats.num_trades,
        "win_rate":     stats.win_rate,
        "total_return": stats.total_return,
        "expectancy":   expectancy,
        // Display only (no thresholds): the account at the strategy's
        // sizing, compounded. `total_return`/`max_drawdown` above are the
        // trades added up at a whole account each, which the gates use.
        "account_return":       stats.account_return,
        "account_max_drawdown": stats.account_max_drawdown.abs(),
        "account_risk_pct":     stats.account_risk_pct,
        // Both drawdowns value open trades at every bar's close; results
        // saved before this was so lack the key.
        "drawdown_valued":      "every_close",
    });
    if let Some(months) = stats.num_months {
        json["num_months"] = serde_json::json!(months);
        json["judged_on"] = serde_json::json!("months");
    }
    json
}

pub async fn run_backtest(pool: &PgPool, config: &StrategyConfig) -> AppResult<EvaluationResult> {
    let evaluation_id = upsert_evaluation_running(pool, config.id, "backtest").await?;

    let subject = match load_subject(pool, config, true).await? {
        Ok(subject) => subject,
        Err(failure) => return fail_stage(pool, evaluation_id, failure).await,
    };
    if subject.single().is_some_and(<[Candle]>::is_empty) {
        let failure = format!(
            "no candle data for {} {}",
            config.instrument, config.granularity
        );
        return fail_stage(pool, evaluation_id, failure).await;
    }

    let financing = load_financing(pool).await?;
    let costs = costs_json(config, &financing);
    let held = subject.hold(&config.instrument, &financing);
    let job = config.clone();
    let tested = match off_runtime(move || subject.test(&job, &financing, Part::Whole)).await? {
        Ok(tested) => tested,
        Err(failure) => return fail_stage(pool, evaluation_id, failure).await,
    };

    let mut stats_json = backtest_stats_to_json(&tested.stats);
    if let Some(extra) = tested.basket {
        stats_json["basket"] = extra;
    }
    if let Some(costs) = costs {
        stats_json["costs"] = costs;
    }
    if let Some(held) = held {
        // The rule's own account valued every day, as holding is, on the
        // same footing as holding's figures beside it.
        let rule = path_stats(days(&tested.daily, &tested.lows));
        stats_json["buy_and_hold"] = serde_json::json!(held);
        stats_json["buy_and_hold"]["rule"] = serde_json::json!({
            "annual_sharpe": rule.annual_sharpe,
            "total_return": rule.total_return,
            "max_drawdown": rule.max_drawdown,
        });
    }
    let result = judge(pool, config, evaluation_id, "backtest", stats_json).await?;

    tracing::info!(
        config_id = %config.id,
        instrument = %config.instrument,
        granularity = %config.granularity,
        strategy_type = %config.strategy_type,
        stage = "backtest",
        status = %result.status,
        num_trades = tested.stats.num_trades,
        sharpe = tested.stats.sharpe_ratio,
        "pipeline stage complete"
    );

    Ok(result)
}

// ---------------------------------------------------------------------------
// Walk-forward stage
// ---------------------------------------------------------------------------

fn walk_forward_stats_to_json(is_stats: &BacktestStats, oos_stats: &BacktestStats) -> Value {
    let sharpe_retention = if is_stats.sharpe_ratio.abs() < f64::EPSILON {
        0.0
    } else {
        oos_stats.sharpe_ratio / is_stats.sharpe_ratio
    };

    let mut json = serde_json::json!({
        // Evaluated against thresholds
        "oos_sharpe":       oos_stats.sharpe_ratio,
        "oos_annual_sharpe": oos_stats.annual_sharpe,
        "oos_t_stat":       t_stat(oos_stats),
        "oos_return":       oos_stats.total_return,
        "oos_num_trades":   oos_stats.num_trades,
        "sharpe_retention": sharpe_retention,
        // Context only — not threshold-evaluated
        "is_sharpe":        is_stats.sharpe_ratio,
        "is_num_trades":    is_stats.num_trades,
        "is_return":        is_stats.total_return,
        // Display only: the account at the strategy's sizing, compounded.
        "oos_account_return": oos_stats.account_return,
        "is_account_return":  is_stats.account_return,
        "account_risk_pct":   oos_stats.account_risk_pct,
    });
    // A ranked basket: its halves' months, for its months minimums.
    if let (Some(is), Some(oos)) = (is_stats.num_months, oos_stats.num_months) {
        json["is_num_months"] = serde_json::json!(is);
        json["oos_num_months"] = serde_json::json!(oos);
        json["judged_on"] = serde_json::json!("months");
    }
    json
}

/// The fewest trades a try needs for its Sharpe to count toward the
/// recorded spread of tries (information only): the backtest stage's own `num_trades` minimum, or 2 (the least
/// any Sharpe needs) when there's no such rule.
fn min_trades(backtest_thresholds: &[ThresholdRow]) -> usize {
    backtest_thresholds
        .iter()
        .find(|t| t.metric == "num_trades")
        .map(|t| match t.operator.as_str() {
            "gt" => t.value.floor() as usize + 1,
            _ => t.value.ceil() as usize,
        })
        .unwrap_or(2)
        .max(2)
}

/// The deflated Sharpe and what went into it, for the walk-forward stats:
/// the config's whole-window backtest (`stats`, `returns`: its per-trade
/// Sharpe, trade count, skew and kurtosis; a ranked basket's are its
/// months', `Tested::returns`) against the tries of its idea,
/// `family`. N counts the distinct (market, settings) tries: the
/// pipeline's (`tries` of this family, any instrument or timeframe, tiny
/// ones included) together with `research_markets`, each market counting
/// as √k for its k settings (`deflated_sharpe::count_tries`). The bar is how good the best of N tries would
/// look if none had an edge (`deflated_sharpe` module doc). The tries'
/// actual spread (pipeline tries with at least `min_trades` trades) is
/// recorded beside it for information; it doesn't move the bar.
/// `deflated_sharpe` is null when it can't be computed, which fails its
/// threshold as "missing from stats".
fn deflated_sharpe_json(
    family: &str,
    stats: &BacktestStats,
    returns: &[f64],
    tries: &[pipeline_repo::BacktestTry],
    research_markets: &[String],
    min_trades: usize,
) -> Value {
    let own: Vec<&pipeline_repo::BacktestTry> = tries
        .iter()
        .filter(|t| deflated_sharpe::family(&t.strategy_type, &t.parameters) == family)
        .collect();
    let pipeline_tries: Vec<(String, String)> = own
        .iter()
        .map(|t| {
            (
                deflated_sharpe::market(&t.instrument, &t.granularity, &t.parameters),
                deflated_sharpe::settings(&t.parameters),
            )
        })
        .collect();
    let pipeline_markets: BTreeSet<&str> = pipeline_tries.iter().map(|(m, _)| m.as_str()).collect();
    let pipeline_markets = pipeline_markets.len();
    let counted = deflated_sharpe::count_tries(pipeline_tries, research_markets);
    let n_trials = counted.effective;
    let scores: Vec<(f64, usize)> = own
        .iter()
        .map(|t| (t.sharpe, usize::try_from(t.periods).unwrap_or(0)))
        .collect();
    let spread = deflated_sharpe::z_spread(&scores, min_trades);
    let z0 = deflated_sharpe::expected_max(n_trials, 1.0);
    // Trades, or a ranked basket's months.
    let periods = stats.periods();
    let sr0 = deflated_sharpe::sharpe_bar(z0, periods);
    let moments = deflated_sharpe::skew_kurtosis(returns);
    let dsr = moments.and_then(|(skew, kurtosis)| {
        deflated_sharpe::deflated_sharpe(stats.sharpe_ratio, sr0, periods, skew, kurtosis)
    });

    serde_json::json!({
        // Evaluated against thresholds
        "deflated_sharpe":  dsr,
        // Context only: the inputs, for checking it by hand
        "family":           family,
        // N: each market as √k for its k distinct settings (rounded up)
        "n_trials":         n_trials,
        "n_markets":        counted.markets,
        "n_settings":       counted.settings,
        "pipeline_markets": pipeline_markets,
        "research_markets": research_markets.len(),
        "z":                deflated_sharpe::z_score(stats.sharpe_ratio, periods),
        // Information only, not used for the bar: how much the family's
        // tries actually differ, and on how many full-sized tries.
        "vz_raw":           spread.raw,
        "vz_tries":         spread.tries,
        "vz_min_trades":    min_trades,
        "z0":               z0,
        "sr0":              sr0,
        "bt_sharpe":        stats.sharpe_ratio,
        "bt_num_trades":    stats.num_trades,
        "bt_skew":          moments.map(|(skew, _)| skew),
        "bt_kurtosis":      moments.map(|(_, kurtosis)| kurtosis),
    })
}

pub async fn run_walk_forward(
    pool: &PgPool,
    config: &StrategyConfig,
) -> AppResult<EvaluationResult> {
    let evaluation_id = upsert_evaluation_running(pool, config.id, "walk_forward").await?;

    let subject = match load_subject(pool, config, true).await? {
        Ok(subject) => subject,
        Err(failure) => return fail_stage(pool, evaluation_id, failure).await,
    };
    // Need enough candles for a meaningful OOS window
    if let Some(candles) = subject.single().filter(|c| c.len() < 50) {
        let failure = format!(
            "insufficient candles for walk_forward: {} (need >= 50)",
            candles.len()
        );
        return fail_stage(pool, evaluation_id, failure).await;
    }

    let financing = load_financing(pool).await?;
    let job = config.clone();
    // 70/30 split: IS is the first 70%, OOS is the last 30%. The whole
    // window is run too, as the backtest stage runs it, for the deflated
    // Sharpe (its trades' skew and kurtosis).
    let (is_run, oos_run, full_run) = off_runtime(move || {
        (
            subject.test(&job, &financing, Part::InSample),
            subject.test(&job, &financing, Part::OutOfSample),
            subject.test(&job, &financing, Part::Whole),
        )
    })
    .await?;

    let is = match is_run {
        Ok(t) => t,
        Err(e) => {
            let failure = format!("IS run failed: {}", e);
            return fail_stage(pool, evaluation_id, failure).await;
        }
    };

    let oos = match oos_run {
        Ok(t) => t,
        Err(e) => {
            let failure = format!("OOS run failed: {}", e);
            return fail_stage(pool, evaluation_id, failure).await;
        }
    };

    let full = match full_run {
        Ok(t) => t,
        Err(e) => {
            let failure = format!("full-window run failed: {}", e);
            return fail_stage(pool, evaluation_id, failure).await;
        }
    };

    let tries = pipeline_repo::list_backtest_tries(pool)
        .await
        .map_err(AppError::Database)?;
    let family = deflated_sharpe::family(&config.strategy_type, &config.parameters);
    let research_markets = pipeline_repo::list_research_markets(pool, &family)
        .await
        .map_err(AppError::Database)?;
    let backtest_thresholds = load_thresholds(
        pool,
        "backtest",
        config.granularity.timeframe_class(),
        instrument_to_class(&config.instrument),
        &config.strategy_type,
    )
    .await?;
    let mut stats_json = walk_forward_stats_to_json(&is.stats, &oos.stats);
    let deflated = deflated_sharpe_json(
        &family,
        &full.stats,
        &full.returns,
        &tries,
        &research_markets,
        min_trades(&backtest_thresholds),
    );
    if let (Some(stats), Value::Object(extra)) = (stats_json.as_object_mut(), deflated) {
        stats.extend(extra);
    }
    let result = judge(pool, config, evaluation_id, "walk_forward", stats_json).await?;

    tracing::info!(
        config_id = %config.id,
        instrument = %config.instrument,
        granularity = %config.granularity,
        strategy_type = %config.strategy_type,
        stage = "walk_forward",
        status = %result.status,
        is_trades = is.stats.num_trades,
        oos_trades = oos.stats.num_trades,
        is_sharpe = is.stats.sharpe_ratio,
        oos_sharpe = oos.stats.sharpe_ratio,
        deflated_sharpe = ?result.stats.get("deflated_sharpe"),
        "pipeline stage complete"
    );

    Ok(result)
}

// ---------------------------------------------------------------------------
// Monte Carlo stage
// ---------------------------------------------------------------------------

const MONTE_CARLO_SIMS: usize = 10_000;

/// Mean length, in trading days, of the stretches Monte Carlo redraws
/// (about a month): runs of losses and calm or wild spells stay together,
/// where redrawing single trades or days independently breaks them up and
/// makes a bad run look shallower than it is.
const MEAN_BLOCK_DAYS: f64 = 20.0;

/// How Monte Carlo redraws, saved with its results so older results
/// (trades or months redrawn one at a time, drawdown between trades only)
/// can be told apart.
const MC_METHOD: &str = "daily_block_bootstrap";

/// Fill `out` with `len` positions in a series of `n` (n ≥ 1), drawn by the
/// stationary bootstrap (Politis & Romano 1994): start anywhere, then each
/// step either carries on to the next position (wrapping from the end to
/// the start) or, with chance 1/`mean_block`, jumps to a fresh random
/// start. Stretches come out `mean_block` long on average (geometric), so
/// whatever clusters within about that span is kept together.
fn stationary_bootstrap<R: rand::Rng + ?Sized>(
    n: usize,
    len: usize,
    mean_block: f64,
    rng: &mut R,
    out: &mut Vec<usize>,
) {
    out.clear();
    let restart = 1.0 / mean_block;
    let mut at = rng.random_range(0..n);
    for i in 0..len {
        if i > 0 {
            at = if rng.random::<f64>() < restart {
                rng.random_range(0..n)
            } else {
                (at + 1) % n
            };
        }
        out.push(at);
    }
}

/// One redrawn path's figures.
struct PathStats {
    total_return: f64,
    /// Worst fall from the high (≥ 0), the start counting as a high.
    max_drawdown: f64,
    annual_sharpe: f64,
}

/// Each day's return beside its low (`Outcome::daily_lows`); with no lows
/// (a held fund's daily closes) the day's low is its close.
fn days<'a>(daily: &'a [f64], lows: &'a [f64]) -> impl Iterator<Item = (f64, f64)> + 'a {
    daily
        .iter()
        .enumerate()
        .map(|(i, &r)| (r, lows.get(i).map_or(r, |low| low.min(r))))
}

/// Compound `daily` (the account's returns, each with the day's low, in
/// the order drawn). The drawdown sees the day's low, so a dip inside a
/// day that recovers by its close still counts, as in the backtest.
fn path_stats(daily: impl Iterator<Item = (f64, f64)>) -> PathStats {
    let (mut nav, mut peak, mut max_drawdown) = (1.0_f64, 1.0_f64, 0.0_f64);
    let (mut n, mut sum, mut sum_sq) = (0.0_f64, 0.0_f64, 0.0_f64);
    for (r, low) in daily {
        max_drawdown = max_drawdown.max(1.0 - (nav * (1.0 + low)).max(0.0) / peak);
        nav = (nav * (1.0 + r)).max(0.0);
        peak = peak.max(nav);
        max_drawdown = max_drawdown.max(1.0 - nav / peak);
        n += 1.0;
        sum += r;
        sum_sq += r * r;
    }
    let mean = sum / n;
    let sd = (sum_sq / n - mean * mean).max(0.0).sqrt();
    PathStats {
        total_return: nav - 1.0,
        max_drawdown,
        annual_sharpe: if sd > f64::EPSILON {
            mean / sd * 252f64.sqrt()
        } else {
            0.0
        },
    }
}

/// The value `pct`% of the way up `sorted` (index n·pct/100, the 95th of
/// 10,000 being the 9,500th).
fn percentile(sorted: &[f64], pct: usize) -> f64 {
    sorted[(sorted.len() * pct / 100).min(sorted.len() - 1)]
}

/// Redraw the account's daily returns (`Outcome::daily_valued`: valued at
/// each day's last bar, open trades included, sized as live sizes them)
/// `MONTE_CARLO_SIMS` times by the stationary block bootstrap, each path as
/// long as the original, and read every figure off the redrawn paths: the
/// share that made money, and the drawdown and return percentiles, all on
/// the backtest's `account_*` basis. A trade's dip while open counts, its
/// dip inside a day too (each day is redrawn with its low, `lows`; empty:
/// none), and so do runs of bad days.
fn run_monte_carlo_sims<R: rand::Rng + ?Sized>(daily: &[f64], lows: &[f64], rng: &mut R) -> Value {
    let n = daily.len();
    let mut picks = Vec::with_capacity(n);
    let mut profitable = 0_usize;
    let mut returns = Vec::with_capacity(MONTE_CARLO_SIMS);
    let mut drawdowns = Vec::with_capacity(MONTE_CARLO_SIMS);
    let mut sharpes = Vec::with_capacity(MONTE_CARLO_SIMS);
    for _ in 0..MONTE_CARLO_SIMS {
        stationary_bootstrap(n, n, MEAN_BLOCK_DAYS, rng, &mut picks);
        let path = path_stats(picks.iter().map(|&i| {
            let r = daily[i];
            (r, lows.get(i).map_or(r, |low| low.min(r)))
        }));
        profitable += usize::from(path.total_return > 0.0);
        returns.push(path.total_return);
        drawdowns.push(path.max_drawdown);
        sharpes.push(path.annual_sharpe);
    }
    for v in [&mut returns, &mut drawdowns, &mut sharpes] {
        v.sort_by(f64::total_cmp);
    }

    serde_json::json!({
        // Evaluated against thresholds
        "profitable_pct": profitable as f64 / MONTE_CARLO_SIMS as f64,
        "p95_drawdown": percentile(&drawdowns, 95),
        // Context only
        "median_drawdown": percentile(&drawdowns, 50),
        "p5_return": percentile(&returns, 5),
        "median_return": percentile(&returns, 50),
        "p95_return": percentile(&returns, 95),
        "median_annual_sharpe": percentile(&sharpes, 50),
        "num_days": n,
        "num_sims": MONTE_CARLO_SIMS,
        "mean_block_days": MEAN_BLOCK_DAYS,
        "mc_method": MC_METHOD,
    })
}

/// For shares held outright, Monte Carlo judged against just holding the
/// same funds (`held`) instead of a fixed drawdown cap: the rule's daily
/// account returns scaled to swing as much as holding does, their 95th
/// percentile bad run beside holding's, redrawn the same way
/// (`p95_drawdown_vs_hold`, 1 = as bad: like for like, so a rule that just
/// held would score about 1, not fail against holding's one lucky or
/// unlucky history), and the rule's Sharpe less
/// holding's (`sharpe_vs_hold`). Scaling makes it fair however small the
/// rule's positions are; Sharpe doesn't change with scale.
fn against_holding<R: rand::Rng + ?Sized>(
    stats: &mut Value,
    daily: &[f64],
    lows: &[f64],
    held: &Hold,
    rng: &mut R,
) {
    let rule = path_stats(days(daily, lows));
    let n = daily.len() as f64;
    let mean = daily.iter().sum::<f64>() / n;
    let vol = (daily.iter().map(|r| (r - mean).powi(2)).sum::<f64>() / n).sqrt() * 252f64.sqrt();
    let scale = if vol > f64::EPSILON {
        held.annual_vol / vol
    } else {
        1.0
    };
    let scaled: Vec<f64> = daily.iter().map(|r| r * scale).collect();
    let scaled_lows: Vec<f64> = lows.iter().map(|r| r * scale).collect();
    let at_hold_risk = run_monte_carlo_sims(&scaled, &scaled_lows, rng)["p95_drawdown"]
        .as_f64()
        .unwrap_or(f64::NAN);
    let hold_p95 = run_monte_carlo_sims(&held.daily, &[], rng)["p95_drawdown"]
        .as_f64()
        .unwrap_or(f64::NAN);
    stats["buy_and_hold"] = serde_json::json!(held);
    stats["buy_and_hold"]["p95_drawdown"] = serde_json::json!(hold_p95);
    stats["buy_and_hold"]["rule"] = serde_json::json!({
        "annual_sharpe": rule.annual_sharpe,
        "total_return": rule.total_return,
        "max_drawdown": rule.max_drawdown,
        "annual_vol": vol,
    });
    stats["p95_drawdown_at_hold_risk"] = serde_json::json!(at_hold_risk);
    stats["p95_drawdown_vs_hold"] = if hold_p95 > f64::EPSILON {
        serde_json::json!(at_hold_risk / hold_p95)
    } else {
        Value::Null
    };
    stats["sharpe_vs_hold"] = serde_json::json!(rule.annual_sharpe - held.annual_sharpe);
}

pub async fn run_monte_carlo(
    pool: &PgPool,
    config: &StrategyConfig,
) -> AppResult<EvaluationResult> {
    let evaluation_id = upsert_evaluation_running(pool, config.id, "monte_carlo").await?;

    let subject = match load_subject(pool, config, true).await? {
        Ok(subject) => subject,
        Err(failure) => return fail_stage(pool, evaluation_id, failure).await,
    };

    let financing = load_financing(pool).await?;
    let held = subject.hold(&config.instrument, &financing);
    let job = config.clone();
    let tested = match off_runtime(move || subject.test(&job, &financing, Part::Whole)).await? {
        Ok(tested) => tested,
        Err(failure) => return fail_stage(pool, evaluation_id, failure).await,
    };
    let (daily, lows) = (tested.daily, tested.lows);
    // Days the account moved: a strategy that never traded has none to
    // redraw.
    let moved = daily.iter().filter(|r| **r != 0.0).count();
    if moved < 2 {
        let failure = format!("too few days with results for Monte Carlo: {moved} (need >= 2)");
        return fail_stage(pool, evaluation_id, failure).await;
    }

    let num_days = daily.len();
    let stats_json = off_runtime(move || {
        let mut stats = run_monte_carlo_sims(&daily, &lows, &mut rand::rng());
        if let Some(held) = held {
            against_holding(&mut stats, &daily, &lows, &held, &mut rand::rng());
        }
        stats
    })
    .await?;
    let result = judge(pool, config, evaluation_id, "monte_carlo", stats_json).await?;

    tracing::info!(
        config_id = %config.id,
        instrument = %config.instrument,
        granularity = %config.granularity,
        strategy_type = %config.strategy_type,
        stage = "monte_carlo",
        status = %result.status,
        num_days = num_days,
        sims = MONTE_CARLO_SIMS,
        "pipeline stage complete"
    );

    Ok(result)
}

// ---------------------------------------------------------------------------
// Parameter stability stage
// ---------------------------------------------------------------------------

/// A neighbour's backtest, or why it couldn't be run.
type NeighbourRun = (
    parameter_stability::Neighbour,
    Result<BacktestStats, String>,
);

/// Backtest one neighbour like the backtest stage does (a basket's on the
/// whole basket). `Err` is a neighbour
/// not worth running or that the strategy rejects: outside the range where
/// its block means anything (`Neighbour::skip`), it doesn't parse, its
/// warmup doesn't fit the live buffer, or its blocks can't compute on the
/// last bar when the original's can (a period of 0, a fast average no
/// faster than the slow one).
fn run_neighbour(
    subject: &Subject,
    config: &StrategyConfig,
    financing: &FinancingModel,
    neighbour: &parameter_stability::Neighbour,
    original_computes: bool,
) -> Result<BacktestStats, String> {
    if let Some(why) = neighbour.skip {
        return Err(why.to_string());
    }
    let strategy = parse_strategy(&neighbour.parameters, financing)
        .map_err(|e| format!("not a valid setting: {e}"))?;
    let probe = subject.probe();
    let window = strategy_mod::bounded_window(
        probe,
        probe.len() - 1,
        strategy.granularity.buffer_capacity(),
    );
    if original_computes && strategy.compute_ports(window).is_none() {
        return Err("the strategy can't work with this setting".to_string());
    }
    let job = StrategyConfig {
        parameters: neighbour.parameters.clone(),
        ..config.clone()
    };
    match subject {
        // The same markets under the neighbour's ranking (its `every_bars`).
        Subject::Basket(_, members) => {
            let basket = basket::Basket::of(&job)?.ok_or("the basket settings are missing")?;
            basket::run(members, &basket, &job, financing, basket::Window::Whole)
                .map(|run| run.stats)
        }
        Subject::One(_) => subject
            .test(&job, financing, Part::Whole)
            .map(|tested| tested.stats),
    }
}

/// The original's backtest and every neighbour's, over `subject` (its
/// bars not empty).
fn run_neighbours(
    subject: &Subject,
    config: &StrategyConfig,
    financing: &FinancingModel,
) -> Result<(BacktestStats, Vec<NeighbourRun>), String> {
    let base = subject.test(config, financing, Part::Whole)?.stats;
    // Parsed and written back out, so defaults are present and floats read
    // as floats (`parameter_stability::neighbours`).
    let strategy = parse_strategy(&config.parameters, financing)
        .map_err(|e| format!("invalid strategy parameters: {e}"))?;
    let mut written =
        serde_json::to_value(&strategy).map_err(|e| format!("write strategy back out: {e}"))?;
    // The strategy doesn't carry the basket: put it back so a ranked
    // basket's rebalance spacing gets neighbours too.
    if let (Some(basket), Value::Object(out)) = (config.parameters.get("basket"), &mut written) {
        out.insert("basket".to_string(), basket.clone());
    }
    let probe = subject.probe();
    let window = strategy_mod::bounded_window(
        probe,
        probe.len() - 1,
        strategy.granularity.buffer_capacity(),
    );
    let original_computes = strategy.compute_ports(window).is_some();

    let runs = parameter_stability::neighbours(&written)
        .into_iter()
        .map(|n| {
            let run = run_neighbour(subject, config, financing, &n, original_computes);
            (n, run)
        })
        .collect();
    Ok((base, runs))
}

/// Re-run the strategy with each numeric setting moved one step either way
/// (`parameter_stability`) over the backtest stage's bars and costs. It
/// passes when every neighbour that runs still makes money and keeps at
/// least half the original's Sharpe: the `worst_total_return` and
/// `worst_sharpe_retention` thresholds. A failure names the setting that
/// broke it. Neighbours run one after another on one blocking thread, so
/// two pipeline jobs at once stay well inside the live feed's headroom.
pub async fn run_parameter_stability(
    pool: &PgPool,
    config: &StrategyConfig,
) -> AppResult<EvaluationResult> {
    let evaluation_id = upsert_evaluation_running(pool, config.id, "parameter_stability").await?;

    let subject = match load_subject(pool, config, true).await? {
        Ok(subject) => subject,
        Err(failure) => return fail_stage(pool, evaluation_id, failure).await,
    };
    if subject.single().is_some_and(<[Candle]>::is_empty) {
        let failure = format!(
            "no candle data for {} {}",
            config.instrument, config.granularity
        );
        return fail_stage(pool, evaluation_id, failure).await;
    }

    let financing = load_financing(pool).await?;
    let job = config.clone();
    let (base, runs) = match off_runtime(move || run_neighbours(&subject, &job, &financing)).await?
    {
        Ok(result) => result,
        Err(failure) => return fail_stage(pool, evaluation_id, failure).await,
    };

    if base.sharpe_ratio <= 0.0 {
        let failure = format!(
            "Its own backtest Sharpe is {:.2}, not above zero, so there is no edge to keep",
            base.sharpe_ratio
        );
        return fail_stage(pool, evaluation_id, failure).await;
    }

    let timeframe_class = config.granularity.timeframe_class();
    let instrument_class = instrument_to_class(&config.instrument);
    let thresholds = load_thresholds(
        pool,
        "parameter_stability",
        timeframe_class,
        instrument_class,
        &config.strategy_type,
    )
    .await?;

    let mut variants = Vec::new();
    let mut skipped = Vec::new();
    // (retention, plain words) for each neighbour that broke it.
    let mut broken: Vec<(f64, String)> = Vec::new();
    let mut worst_retention = f64::INFINITY;
    let mut worst_return = f64::INFINITY;
    for (n, run) in &runs {
        let stats = match run {
            Ok(stats) => stats,
            Err(reason) => {
                skipped.push(serde_json::json!({
                    "setting": n.setting, "kind": n.kind, "from": n.from, "value": n.to,
                    "reason": reason,
                }));
                continue;
            }
        };
        let retention = stats.sharpe_ratio / base.sharpe_ratio;
        let passed =
            parameter_stability::neighbour_passes(&thresholds, retention, stats.total_return);
        worst_retention = worst_retention.min(retention);
        worst_return = worst_return.min(stats.total_return);
        variants.push(serde_json::json!({
            "setting":          n.setting,
            "kind":             n.kind,
            "from":             n.from,
            "value":            n.to,
            "sharpe":           stats.sharpe_ratio,
            "total_return":     stats.total_return,
            "num_trades":       stats.num_trades,
            "sharpe_retention": retention,
            "passed":           passed,
        }));
        if !passed {
            // Whether the Sharpe bar alone held: an unbounded return can't fail.
            let retention_ok =
                parameter_stability::neighbour_passes(&thresholds, retention, f64::MAX);
            let words = parameter_stability::failure_words(
                n,
                base.sharpe_ratio,
                stats.sharpe_ratio,
                stats.total_return,
                retention_ok,
            );
            broken.push((retention, words));
        }
    }

    let tested = variants.len();
    let mut stats_json = serde_json::json!({
        // Evaluated against thresholds (null when nothing could be tested)
        "worst_sharpe_retention": (tested > 0).then_some(worst_retention),
        "worst_total_return":     (tested > 0).then_some(worst_return),
        // Context only
        "base_sharpe":       base.sharpe_ratio,
        "base_total_return": base.total_return,
        "base_num_trades":   base.num_trades,
        "tested":            tested,
        "variants":          variants,
        "skipped":           skipped,
    });
    let (status, failure_reason) = evaluate_thresholds(
        &mut stats_json,
        &thresholds,
        "parameter_stability",
        timeframe_class,
    );
    let failure_reason = match (status.as_str(), tested) {
        ("failed", 0) if !thresholds.is_empty() => Some(
            "No setting could be moved and still run, so stability can't be judged".to_string(),
        ),
        ("failed", _) if !broken.is_empty() => {
            broken.sort_by(|a, b| a.0.total_cmp(&b.0));
            let others = broken.len() - 1;
            Some(if others == 0 {
                broken[0].1.clone()
            } else {
                format!(
                    "{}; {} more of the {} moves also broke it",
                    broken[0].1, others, tested
                )
            })
        }
        _ => failure_reason,
    };

    finalize_evaluation(
        pool,
        evaluation_id,
        &status,
        &stats_json,
        failure_reason.as_deref(),
    )
    .await?;

    tracing::info!(
        config_id = %config.id,
        instrument = %config.instrument,
        granularity = %config.granularity,
        strategy_type = %config.strategy_type,
        stage = "parameter_stability",
        status = %status,
        tested = tested,
        skipped = runs.len() - tested,
        worst_sharpe_retention = worst_retention,
        "pipeline stage complete"
    );

    Ok(EvaluationResult {
        evaluation_id,
        status,
        stats: stats_json,
        failure_reason,
    })
}

#[cfg(test)]
mod tests {

    #[test]
    fn a_share_market_is_tested_from_its_first_known_dividend() {
        use crate::engine::financing::{BrokerCosts, Overnight};
        let day = |d: u32| chrono::TimeZone::with_ymd_and_hms(&Utc, 2007, 3, d, 4, 0, 0).unwrap();
        let candles: Vec<Candle> = (14..=19)
            .map(|d| {
                Candle::from_trade_bar(
                    day(d),
                    crate::engine::types::OHLC {
                        open: 1.0,
                        high: 1.0,
                        low: 1.0,
                        close: 1.0,
                    },
                    0.0,
                )
            })
            .collect();
        let owned = BrokerCosts {
            broker: "wealthsimple".into(),
            overnight: Overnight::None,
            spread_bps: Some(10.0),
            commission_bps: 0.0,
            can_short: false,
        };
        let first = chrono::NaiveDate::from_ymd_opt(2007, 3, 16).unwrap();
        let financing = FinancingModel::default()
            .with_brokers(vec![("DIA".into(), owned.clone()), ("GLD".into(), owned)])
            .with_dividends(vec![
                ("DIA".into(), vec![(first, 0.5)]),
                ("GLD".into(), vec![]),
            ]);

        let dia = from_known_dividends(candles.clone(), "DIA", &financing);
        assert_eq!(dia.len(), 4, "the 16th on");
        assert_eq!(
            from_known_dividends(candles.clone(), "GLD", &financing).len(),
            6
        );
        assert_eq!(
            from_known_dividends(candles.clone(), "SPX500_USD", &financing).len(),
            6
        );
        // No history to fetch (a Canadian listing): its recorded dividends
        // don't clip the test.
        let financing =
            financing.with_recorded_dividends(vec![("XIU.TO".into(), vec![(first, 0.3)])]);
        assert_eq!(from_known_dividends(candles, "XIU.TO", &financing).len(), 6);
    }

    #[test]
    fn owned_shares_are_judged_against_holding_at_holdings_risk() {
        use rand::SeedableRng;
        // A small, steady rule: tiny positions, so its own drops are tiny.
        let daily: Vec<f64> = (0..600)
            .map(|i| if i % 5 == 0 { -0.002 } else { 0.001 })
            .collect();
        let held = Hold {
            total_return: 1.0,
            annual_return: 0.08,
            max_drawdown: 0.40,
            annual_sharpe: 0.5,
            annual_vol: 0.16,
            first_day: chrono::NaiveDate::from_ymd_opt(2010, 1, 4).unwrap(),
            last_day: chrono::NaiveDate::from_ymd_opt(2012, 6, 1).unwrap(),
            daily: (0..600)
                .map(|i| if i % 7 == 0 { -0.03 } else { 0.006 })
                .collect(),
        };
        let mut stats = serde_json::json!({});
        let mut rng = rand::rngs::StdRng::seed_from_u64(7);
        against_holding(&mut stats, &daily, &[], &held, &mut rng);

        let rule_sharpe = stats["buy_and_hold"]["rule"]["annual_sharpe"]
            .as_f64()
            .unwrap();
        assert!((stats["sharpe_vs_hold"].as_f64().unwrap() - (rule_sharpe - 0.5)).abs() < 1e-12);
        // Scaled up to swing like holding, its bad run is far bigger than
        // its own tiny drops, and is read against holding's own bad run.
        let at_risk = stats["p95_drawdown_at_hold_risk"].as_f64().unwrap();
        assert!(
            at_risk
                > stats["buy_and_hold"]["rule"]["max_drawdown"]
                    .as_f64()
                    .unwrap()
        );
        let hold_p95 = stats["buy_and_hold"]["p95_drawdown"].as_f64().unwrap();
        assert!(
            (stats["p95_drawdown_vs_hold"].as_f64().unwrap() - at_risk / hold_p95).abs() < 1e-12
        );
    }

    #[test]
    fn a_rule_that_just_holds_scores_about_as_bad_as_holding() {
        use rand::SeedableRng;
        let daily: Vec<f64> = (0..1500)
            .map(|i| match i % 9 {
                0 => -0.025,
                4 => -0.01,
                _ => 0.006,
            })
            .collect();
        let held = Hold {
            total_return: 1.0,
            annual_return: 0.08,
            max_drawdown: 0.05,
            annual_sharpe: 0.5,
            annual_vol: {
                let n = daily.len() as f64;
                let m = daily.iter().sum::<f64>() / n;
                (daily.iter().map(|r| (r - m).powi(2)).sum::<f64>() / n).sqrt() * 252f64.sqrt()
            },
            first_day: chrono::NaiveDate::from_ymd_opt(2010, 1, 4).unwrap(),
            last_day: chrono::NaiveDate::from_ymd_opt(2015, 12, 31).unwrap(),
            daily: daily.clone(),
        };
        let mut stats = serde_json::json!({});
        let mut rng = rand::rngs::StdRng::seed_from_u64(11);
        against_holding(&mut stats, &daily, &[], &held, &mut rng);
        let ratio = stats["p95_drawdown_vs_hold"].as_f64().unwrap();
        assert!((ratio - 1.0).abs() < 0.1, "ratio {ratio}");
    }

    #[test]
    fn long_only_drops_the_short_entry_and_keeps_the_rest() {
        let parameters = serde_json::json!({
            "entry": {"long": "r.oversold", "short": "r.overbought"},
            "exit": {"long": "r.overbought", "short": "r.oversold"}
        });
        let long = long_only(&parameters);
        assert_eq!(long["entry"], serde_json::json!({"long": "r.oversold"}));
        assert_eq!(long["exit"], parameters["exit"]);
    }
    use super::*;

    const SIZING: AccountSizing = AccountSizing {
        risk_pct: 0.01,
        max_position_pct: 0.15,
    };

    #[test]
    fn monte_carlo_drawdown_counts_losses_before_the_first_gain() {
        let path = path_stats(days(&[-0.3, 0.1, 0.1], &[]));
        assert!((path.max_drawdown - 0.3).abs() < 1e-12);
        assert!((path.total_return - (0.7 * 1.1 * 1.1 - 1.0)).abs() < 1e-12);
    }
    use chrono::Utc;

    use crate::engine::types::{Direction, EntryReason, ExitReason, Trade};

    fn trade_with_pnl(pnl: f64) -> Trade {
        Trade {
            direction: Direction::Long,
            entry_price: 1.0,
            exit_price: 1.0,
            entry_time: Utc::now(),
            exit_time: Utc::now(),
            pnl_percent: pnl,
            entry_reason: EntryReason::CrossAbove {
                fast_ma: 0.0,
                slow_ma: 0.0,
            },
            exit_reason: ExitReason::TrendReversal,
            stop_price: 0.0,
        }
    }

    fn threshold(metric: &str, operator: &str, value: f64) -> ThresholdRow {
        ThresholdRow {
            metric: metric.to_string(),
            operator: operator.to_string(),
            value,
        }
    }

    #[test]
    fn a_dip_inside_a_day_counts_in_the_redrawn_drawdown() {
        // Flat closes, but each day dips 8% before recovering.
        let daily = vec![0.0; 50];
        let lows = vec![-0.08; 50];
        assert!((path_stats(days(&daily, &lows)).max_drawdown - 0.08).abs() < 1e-12);
        assert_eq!(path_stats(days(&daily, &[])).max_drawdown, 0.0);

        let mc = mc_with_lows(&daily, &lows);
        assert!((mc["p95_drawdown"].as_f64().unwrap() - 0.08).abs() < 1e-12);
        assert_eq!(mc["profitable_pct"].as_f64().unwrap(), 0.0);
    }

    fn mc_with_lows(daily: &[f64], lows: &[f64]) -> Value {
        run_monte_carlo_sims(daily, lows, &mut StdRng::seed_from_u64(1))
    }

    #[test]
    fn every_check_is_recorded_with_what_it_needed_and_got() {
        let mut stats = serde_json::json!({"num_trades": 40.0, "t_stat": 1.5});
        let (status, failure) = evaluate_thresholds(
            &mut stats,
            &[
                threshold("num_trades", "gte", 30.0),
                threshold("t_stat", "gte", 2.0),
            ],
            "backtest",
            "H4",
        );

        assert_eq!(status, "failed");
        assert_eq!(
            failure.as_deref(),
            Some("t_stat: 1.5000 is below minimum 2.0000")
        );
        assert_eq!(
            stats["checks"],
            serde_json::json!([
                {"metric": "num_trades", "operator": "gte", "required": 30.0, "actual": 40.0, "passed": true},
                {"metric": "t_stat", "operator": "gte", "required": 2.0, "actual": 1.5, "passed": false}
            ])
        );
    }

    fn carry_config(instrument: &str) -> StrategyConfig {
        StrategyConfig {
            id: Uuid::nil(),
            instrument: instrument.to_string(),
            granularity: Granularity::D,
            strategy_type: "composite".to_string(),
            parameters: serde_json::json!({
                "version": "1", "instrument": instrument, "granularity": "D",
                "components": {"c": {"type": "Carry", "params": {}}},
                "entry": {"long": "c.long", "short": "c.short"},
                "exit": {"long": "c.short", "short": "c.long"},
                "stop": {"type": "FixedPct", "params": {"pct": -0.5}},
                "sizing": {"type": "RiskPct", "params": {"pct": 0.01}},
            }),
        }
    }

    #[test]
    fn a_carry_strategy_backtests_on_the_financing_models_policy_rates() {
        // EUR 2% against USD 5%: EUR_USD carries −3 points, so it sells short
        // on the first bar it can and holds to the end.
        let d = |y, m, day| chrono::NaiveDate::from_ymd_opt(y, m, day).unwrap();
        let financing = FinancingModel::new(
            vec![
                ("USD".into(), d(2020, 1, 1), 0.05),
                ("EUR".into(), d(2020, 1, 1), 0.02),
            ],
            vec![],
        );
        let candles = crate::engine::test_candles::daily(&[1.10, 1.10, 1.09, 1.08]);
        let trades = run_strategy(&candles, &carry_config("EUR_USD"), &financing).unwrap();
        assert_eq!(trades.len(), 1);
        assert_eq!(trades[0].direction, Direction::Short);
        assert_eq!(trades[0].entry_time, candles[1].time);
    }

    #[test]
    fn a_carry_block_on_an_instrument_without_carry_fails_the_run_loudly() {
        let err = run_strategy(
            &crate::engine::test_candles::daily(&[1.0, 1.0]),
            &carry_config("XAU_USD"),
            &FinancingModel::default(),
        )
        .unwrap_err();
        assert!(err.to_string().contains("isn't a currency pair"), "{err}");
        let err = run_strategy(
            &crate::engine::test_candles::daily(&[1.0, 1.0]),
            &carry_config("EUR_USD"),
            &FinancingModel::default(),
        )
        .unwrap_err();
        assert!(err.to_string().contains("no policy rate"), "{err}");
    }

    #[test]
    fn backtest_stats_show_the_account_beside_the_gated_figures() {
        let trades = vec![trade_with_pnl(0.10), trade_with_pnl(-0.05)];
        let stats = calculate_backtest_stats(&trades, &[], SIZING);
        let json = backtest_stats_to_json(&stats);
        assert!((json["total_return"].as_f64().unwrap() - 0.05).abs() < 1e-12);
        assert!(json["account_return"].as_f64().is_some());
        assert!(json["account_max_drawdown"].as_f64().unwrap() >= 0.0);
        assert_eq!(json["account_risk_pct"].as_f64(), Some(0.01));
    }

    #[test]
    fn a_neighbour_the_strategy_rejects_is_skipped_not_failed() {
        // Fast 4 / slow 5: moving fast up to 5 (or slow down to 4) makes the
        // two averages the same length, which the block refuses to compute.
        let parameters = serde_json::json!({
            "version": "v1_composite", "instrument": "EUR_USD", "granularity": "D",
            "components": {"tf": {"type": "TrendFollowing",
                "params": {"fast_period": 4, "slow_period": 5, "ma_type": "sma"}}},
            "entry": {"long": "tf.bullish_cross", "short": "tf.bearish_cross"},
            "exit": {"long": "tf.bearish_cross", "short": "tf.bullish_cross"},
            "stop": {"type": "FixedPct", "params": {"pct": -0.05}},
            "sizing": {"type": "RiskPct", "params": {"pct": 1.0}},
        });
        let config = StrategyConfig {
            id: Uuid::nil(),
            instrument: "EUR_USD".to_string(),
            granularity: Granularity::D,
            strategy_type: "composite".to_string(),
            parameters,
        };
        let closes: Vec<f64> = (0..80)
            .map(|i| 100.0 + 5.0 * ((i as f64) / 6.0).sin())
            .collect();
        let candles = crate::engine::test_candles::daily(&closes);

        let (base, runs) =
            run_neighbours(&Subject::One(candles), &config, &FinancingModel::default()).unwrap();
        assert!(base.num_trades > 0);

        let outcome: Vec<(String, f64, bool)> = runs
            .iter()
            .map(|(n, run)| (n.setting.clone(), n.to, run.is_ok()))
            .collect();
        assert_eq!(
            outcome,
            vec![
                ("tf.fast_period".to_string(), 3.0, true),
                ("tf.fast_period".to_string(), 5.0, false),
                ("tf.slow_period".to_string(), 4.0, false),
                ("tf.slow_period".to_string(), 6.0, true),
                ("stop.pct".to_string(), -0.045, true),
                ("stop.pct".to_string(), -0.055, true),
            ]
        );
        assert_eq!(
            runs[1].1.as_ref().unwrap_err(),
            "the strategy can't work with this setting"
        );
    }

    #[test]
    fn n_counts_distinct_markets_and_the_spread_uses_full_sized_tries() {
        let rsi = |instrument: &str, granularity: &str, sharpe: f64, num_trades: i64| {
            pipeline_repo::BacktestTry {
                strategy_type: "composite".to_string(),
                parameters: serde_json::json!({"components": {"r": {"type": "RsiReversion"}}}),
                instrument: instrument.to_string(),
                granularity: granularity.to_string(),
                sharpe,
                periods: num_trades,
            }
        };
        let tries = vec![
            rsi("SPX500_USD", "D", 0.05, 200),
            // Another setting on the same market: one more try of the spread, not of N.
            rsi("SPX500_USD", "D", 0.25, 200),
            rsi("NAS100_USD", "D", 0.40, 1),
            pipeline_repo::BacktestTry {
                strategy_type: "mean_reversion".to_string(),
                parameters: serde_json::json!({}),
                ..rsi("EU50_EUR", "D", 3.0, 200)
            },
        ];
        let trades: Vec<Trade> = [0.02, -0.01, 0.03, 0.01]
            .iter()
            .map(|&p| trade_with_pnl(p))
            .collect();
        let stats = calculate_backtest_stats(&trades, &[], SIZING);
        let research = vec!["SPX500_USD@D".to_string(), "DE30_EUR@D".to_string()];

        let own = deflated_sharpe_json("RsiReversion", &stats, &pnls(&trades), &tries, &[], 30);
        let more = deflated_sharpe_json(
            "RsiReversion",
            &stats,
            &pnls(&trades),
            &tries,
            &research,
            30,
        );

        // SPX500 D and NAS100 D; the MeanReversion try isn't this idea.
        assert_eq!(own["n_trials"], 2);
        assert_eq!(own["pipeline_markets"], 2);
        // Research adds DE30 D; SPX500 D was already tried.
        assert_eq!(more["n_trials"], 3);
        assert_eq!(more["research_markets"], 2);
        // The 1-trade NAS100 try is left out of the recorded spread; the bar
        // moves with N only.
        assert_eq!(own["vz_tries"], 2);
        assert_eq!(own["vz_raw"], more["vz_raw"]);
        let z0 = deflated_sharpe::expected_max(3, 1.0);
        assert!((more["z0"].as_f64().unwrap() - z0).abs() < 1e-12);
        assert!(more["sr0"].as_f64() > own["sr0"].as_f64());
    }

    #[test]
    fn n_counts_each_markets_distinct_settings_as_their_root() {
        let rsi = |period: u64, name: &str| pipeline_repo::BacktestTry {
            strategy_type: "composite".to_string(),
            parameters: serde_json::json!({"strategy_name": name, "components": {
                "r": {"type": "RsiReversion", "params": {"rsi_period": period}}}}),
            instrument: "SPX500_USD".to_string(),
            granularity: "D".to_string(),
            sharpe: 0.1,
            periods: 100,
        };
        // RSI 2 to 5 on SPX, RSI 2 retested under another name: 4 settings.
        let tries: Vec<_> = [(2, "a"), (3, "b"), (4, "c"), (5, "d"), (2, "again")]
            .into_iter()
            .map(|(p, n)| rsi(p, n))
            .collect();
        let trades: Vec<Trade> = [0.02, -0.01, 0.03, 0.01]
            .iter()
            .map(|&p| trade_with_pnl(p))
            .collect();
        let stats = calculate_backtest_stats(&trades, &[], SIZING);
        let research = vec!["NAS100_USD@D".to_string()];

        let json = deflated_sharpe_json(
            "RsiReversion",
            &stats,
            &pnls(&trades),
            &tries,
            &research,
            30,
        );

        assert_eq!(json["n_markets"], 2);
        assert_eq!(json["n_settings"], 5);
        // √4 for SPX, 1 for NAS100.
        assert_eq!(json["n_trials"], 3);
        assert_eq!(json["pipeline_markets"], 1);
    }

    #[test]
    fn the_spread_uses_the_backtests_own_minimum_trades() {
        assert_eq!(min_trades(&[threshold("num_trades", "gte", 30.0)]), 30);
        assert_eq!(min_trades(&[threshold("num_trades", "gt", 30.0)]), 31);
        assert_eq!(min_trades(&[threshold("t_stat", "gte", 2.0)]), 2);
    }

    #[test]
    fn a_ranked_basket_swaps_its_trade_minimums_for_months() {
        let rows = || {
            vec![
                threshold("num_trades", "gte", 30.0),
                threshold("t_stat", "gte", 2.0),
                threshold("max_drawdown", "lte", 0.25),
            ]
        };
        let months = vec![
            threshold("num_months", "gte", 36.0),
            // A months rule for another stage's metric isn't pulled in.
            threshold("oos_num_months", "gte", 24.0),
            threshold("t_stat", "gte", 2.0),
        ];
        let (rules, unset) = months_rules(rows(), months);
        let metrics: Vec<&str> = rules.iter().map(|r| r.metric.as_str()).collect();
        assert_eq!(metrics, vec!["t_stat", "max_drawdown", "num_months"]);
        assert!(unset.is_empty());

        // 26 months (a 9-year book's "26 trades" is no longer what counts).
        let mut json = serde_json::json!({
            "num_trades": 26, "num_months": 30, "t_stat": 2.5, "max_drawdown": 0.1,
        });
        let (status, why) = evaluate_thresholds(&mut json, &rules, "backtest", "H4");
        assert_eq!(status, "failed");
        assert!(why
            .unwrap()
            .starts_with("num_months: 30.0000 is below minimum"));
        json["num_months"] = serde_json::json!(40);
        assert_eq!(
            evaluate_thresholds(&mut json, &rules, "backtest", "H4").0,
            "passed"
        );

        // Before the months rules exist: the trades rule is gone and the
        // months one is named as missing, so the stage can't pass unchecked.
        let (rules, unset) = months_rules(rows(), Vec::new());
        assert!(rules.iter().all(|r| r.metric != "num_trades"));
        assert_eq!(unset, vec!["num_months"]);
        // A stage without a trades minimum needs no months rule.
        let (_, unset) = months_rules(vec![threshold("p95_drawdown", "lte", 0.35)], Vec::new());
        assert!(unset.is_empty());
    }

    #[test]
    fn months_figures_are_saved_for_a_ranked_basket_only() {
        let trades: Vec<Trade> = [0.02, -0.01, 0.03, 0.01]
            .iter()
            .map(|&p| trade_with_pnl(p))
            .collect();
        let mut stats = calculate_backtest_stats(&trades, &[], SIZING);
        assert!(backtest_stats_to_json(&stats).get("num_months").is_none());
        stats.judge_by_months(&[0.01, 0.02, -0.01, 0.0, 0.01, 0.02, 0.0, 0.01, 0.03]);
        let json = backtest_stats_to_json(&stats);
        assert_eq!(json["num_months"], 9);
        assert_eq!(json["num_trades"], 4);
        assert_eq!(json["judged_on"], "months");
        // The luck test counts months: √9.
        assert!((json["t_stat"].as_f64().unwrap() - stats.sharpe_ratio * 3.0).abs() < 1e-12);
        let wf = walk_forward_stats_to_json(&stats, &stats);
        assert_eq!(wf["is_num_months"], 9);
        assert_eq!(wf["oos_num_months"], 9);
    }

    fn pnls(trades: &[Trade]) -> Vec<f64> {
        trades.iter().map(|t| t.pnl_percent).collect()
    }

    #[test]
    fn t_stat_is_per_trade_sharpe_times_root_trades() {
        let trades: Vec<Trade> = [0.02, -0.01, 0.03, 0.01]
            .iter()
            .map(|&p| trade_with_pnl(p))
            .collect();
        let stats = calculate_backtest_stats(&trades, &[], SIZING);

        assert!((t_stat(&stats) - stats.sharpe_ratio * 2.0).abs() < 1e-12);
        assert!(backtest_stats_to_json(&stats)["t_stat"].as_f64().is_some());
    }

    use rand::rngs::StdRng;
    use rand::SeedableRng;

    fn mc(daily: &[f64], seed: u64) -> Value {
        run_monte_carlo_sims(daily, &[], &mut StdRng::seed_from_u64(seed))
    }

    fn figure(stats: &Value, key: &str) -> f64 {
        stats[key]
            .as_f64()
            .unwrap_or_else(|| panic!("{key} missing"))
    }

    /// A noisy daily series with a small edge: about ±1% a day around a
    /// +0.03% mean.
    fn noisy_days(n: usize) -> Vec<f64> {
        (0..n)
            .map(|i| 0.01 * (i as f64 * 1.7).sin() + 0.0003)
            .collect()
    }

    #[test]
    fn the_bootstrap_redraws_stretches_of_consecutive_days() {
        let n = 50;
        let mut rng = StdRng::seed_from_u64(7);
        let mut picks = Vec::new();
        let len = 200_000;
        stationary_bootstrap(n, len, MEAN_BLOCK_DAYS, &mut rng, &mut picks);
        assert_eq!(picks.len(), len);
        assert!(picks.iter().all(|&i| i < n));
        // A new stretch starts wherever a pick isn't the one after the last
        // (a fresh start can land there by chance, 1 in n, so slightly
        // fewer are seen than drawn).
        let breaks = picks.windows(2).filter(|w| w[1] != (w[0] + 1) % n).count();
        let mean_block = len as f64 / (breaks + 1) as f64;
        let expected = MEAN_BLOCK_DAYS / (1.0 - 1.0 / n as f64);
        assert!(
            (mean_block - expected).abs() < 0.1 * expected,
            "mean stretch {mean_block}, expected about {expected}"
        );
        // Stretches vary in length (geometric), not one fixed block size.
        let mut lengths = Vec::new();
        let mut run = 1;
        for w in picks.windows(2) {
            if w[1] == (w[0] + 1) % n {
                run += 1;
            } else {
                lengths.push(run);
                run = 1;
            }
        }
        assert!(lengths.iter().any(|&l| l <= 3));
        assert!(lengths.iter().any(|&l| l >= 60));
    }

    #[test]
    fn the_bootstrap_is_the_same_under_the_same_seed() {
        let draw = |seed| {
            let mut picks = Vec::new();
            stationary_bootstrap(
                30,
                500,
                MEAN_BLOCK_DAYS,
                &mut StdRng::seed_from_u64(seed),
                &mut picks,
            );
            picks
        };
        assert_eq!(draw(1), draw(1));
        assert_ne!(draw(1), draw(2));
        let days = noisy_days(300);
        assert_eq!(mc(&days, 3), mc(&days, 3));
        assert_ne!(
            figure(&mc(&days, 3), "median_annual_sharpe"),
            figure(&mc(&days, 4), "median_annual_sharpe")
        );
    }

    #[test]
    fn monte_carlo_says_how_it_redrew() {
        let stats = mc(&noisy_days(300), 1);
        assert_eq!(stats["mc_method"], "daily_block_bootstrap");
        assert_eq!(stats["num_days"], 300);
        assert_eq!(stats["num_sims"], MONTE_CARLO_SIMS);
        assert_eq!(figure(&stats, "mean_block_days"), MEAN_BLOCK_DAYS);
        let made = figure(&stats, "profitable_pct");
        assert!(made > 0.0 && made < 1.0, "{made}");
        assert!(figure(&stats, "p5_return") < figure(&stats, "median_return"));
        assert!(figure(&stats, "median_return") < figure(&stats, "p95_return"));
        assert!(figure(&stats, "median_drawdown") <= figure(&stats, "p95_drawdown"));
    }

    #[test]
    fn monte_carlo_all_gains_or_all_losses() {
        let gains = [0.001, 0.0, 0.002, 0.0, 0.003];
        assert_eq!(figure(&mc(&gains, 1), "profitable_pct"), 1.0);
        assert_eq!(figure(&mc(&gains, 1), "p95_drawdown"), 0.0);
        let losses: Vec<f64> = gains.iter().map(|r| -r).collect();
        assert_eq!(figure(&mc(&losses, 1), "profitable_pct"), 0.0);
    }

    #[test]
    fn monte_carlo_sees_a_long_hold_dip_while_open() {
        // One long trade held eight days: down 10% midway, closed flat. At a
        // 10% stop and 10% risk the whole account is in it. Redrawing its
        // one trade (the old way) saw a 0% drawdown every time; the daily
        // account curve carries the dip.
        let closes = [100.0, 97.0, 94.0, 91.0, 90.0, 92.0, 95.0, 98.0, 100.0];
        let start = DateTime::parse_from_rfc3339("2026-01-05T21:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let bars: Vec<Candle> = closes
            .iter()
            .enumerate()
            .map(|(i, &c)| Candle {
                time: start + chrono::Duration::days(i as i64),
                mid: crate::engine::types::OHLC {
                    open: c,
                    high: c,
                    low: c,
                    close: c,
                },
                volume: 1,
                bid: None,
                ask: None,
            })
            .collect();
        let trade = Trade {
            entry_price: 100.0,
            exit_price: 100.0,
            entry_time: bars[0].time,
            exit_time: bars[8].time,
            stop_price: 90.0,
            ..trade_with_pnl(0.0)
        };
        let sizing = AccountSizing {
            risk_pct: 0.10,
            max_position_pct: 1.0,
        };
        let (stats, outcome) = backtest_on_account(&[trade], &bars, sizing);
        assert!((stats.account_max_drawdown + 0.10).abs() < 1e-12);

        let mc = mc(&outcome.daily_valued, 1);
        // The redrawn paths are stretches of the one dip and recovery: most
        // keep the whole fall together.
        let dd = figure(&mc, "p95_drawdown");
        assert!((0.09..0.2).contains(&dd), "p95 drawdown {dd}");
        assert!(figure(&mc, "median_drawdown") >= 0.05);
    }

    /// Opus compiles the rules version from this file, so it judges results
    /// by the same number the tester stamps them with.
    #[test]
    fn rules_version_file_is_current() {
        const FILE: &str = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../opus/priv/rules_version.json"
        );
        let json = format!("{{\"rules_version\": {RULES_VERSION}}}\n");
        if std::env::var_os("UPDATE_RULES_VERSION").is_some() {
            std::fs::write(FILE, &json).expect("write the rules version");
            return;
        }
        let committed = std::fs::read_to_string(FILE).unwrap_or_default();
        assert!(
            committed == json,
            "opus/priv/rules_version.json is stale: run `UPDATE_RULES_VERSION=1 cargo test rules_version` in auro_be"
        );
    }
}
