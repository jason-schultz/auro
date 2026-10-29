//! `POST /api/strategy/portfolio`: several strategies backtested together on
//! one account, with and without the account safety rules
//! (`engine::portfolio`).
//!
//! Each play is backtested the way the pipeline does it (the bars before
//! the sealed holdout, with financing), then the plays are replayed together
//! over the stretch of history they all have.
//!
//! With `base`, it answers a different question, one row per other play:
//! how that play does next to `base`, each pair over the history the two
//! share. The page ranks those rows to suggest a companion.

use std::collections::hash_map::Entry;
use std::collections::HashMap;
use std::sync::Arc;

use axum::extract::State;
use axum::Json;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{json, Value};

use super::strategy_report::{blocking, config_of, WORKERS};
use crate::engine::live::sizing::MAX_POSITION_PCT_OF_NAV;
use crate::engine::pipeline::{self, run_strategy, StrategyConfig};
use crate::engine::portfolio::{correlation, simulate, Breaker, Limits, Outcome, Play};
use crate::engine::rules::AccountLimits;
use crate::engine::strategy::{SizingConfig, Strategy};
use crate::engine::types::{Candle, Granularity};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

/// Plays one request may carry: a companion search tries every play that
/// passed the walk-forward.
const MAX_PLAYS: usize = 80;

#[derive(Deserialize)]
pub struct PlayRequest {
    pub key: String,
    /// Full strategy JSON (as the report takes it).
    pub parameters: Value,
    #[serde(default)]
    pub breaker_exempt: bool,
}

#[derive(Deserialize)]
pub struct BreakerRequest {
    pub losses: usize,
    pub drawdown: f64,
    pub window_days: i64,
    pub min_trades: usize,
}

#[derive(Deserialize)]
pub struct LimitsRequest {
    pub risk_budget: f64,
    pub max_open_per_group: usize,
    #[serde(default)]
    pub groups: HashMap<String, String>,
    pub drawdown_pause: f64,
    pub breaker: BreakerRequest,
}

#[derive(Deserialize)]
pub struct PortfolioRequest {
    pub plays: Vec<PlayRequest>,
    pub limits: Option<LimitsRequest>,
    /// Key of the play to pair every other play with.
    pub base: Option<String>,
}

/// A play with its backtest and the bars it covers.
struct Tested {
    play: Play,
    granularity: Granularity,
    from: DateTime<Utc>,
    to: DateTime<Utc>,
}

pub async fn portfolio(
    State(state): State<AppState>,
    Json(req): Json<PortfolioRequest>,
) -> AppResult<Json<Value>> {
    if req.plays.is_empty() || req.plays.len() > MAX_PLAYS {
        return Err(AppError::BadRequest(format!(
            "between 1 and {MAX_PLAYS} strategies"
        )));
    }

    let mut configs = Vec::with_capacity(req.plays.len());
    for p in &req.plays {
        configs.push((p, config_of(p.parameters.clone())?));
    }

    // Each instrument and timeframe's bars once, however many plays share them.
    let mut candles: HashMap<(String, Granularity), Arc<Vec<Candle>>> = HashMap::new();
    for (_, config) in &configs {
        let key = (config.instrument.clone(), config.granularity);
        if let Entry::Vacant(slot) = candles.entry(key) {
            let bars = pipeline::load_exploration_candles(&state.db, config).await?;
            slot.insert(Arc::new(bars));
        }
    }
    let financing = Arc::new(pipeline::load_financing(&state.db).await?);

    let jobs: Vec<(String, bool, StrategyConfig, Arc<Vec<Candle>>)> = configs
        .into_iter()
        .map(|(p, config)| {
            let bars = candles[&(config.instrument.clone(), config.granularity)].clone();
            (p.key.clone(), p.breaker_exempt, config, bars)
        })
        .collect();

    let limits = req.limits.map(|l| Limits {
        account: AccountLimits {
            risk_budget: l.risk_budget,
            max_open_per_group: l.max_open_per_group,
            groups: l.groups,
        },
        drawdown_pause: l.drawdown_pause,
        breaker: Breaker {
            losses: l.breaker.losses,
            drawdown: l.breaker.drawdown,
            window_days: l.breaker.window_days,
            min_trades: l.breaker.min_trades,
        },
    });
    let base = req.base;

    let body = blocking(move || {
        let (tested, failed) = backtest_all(jobs, &financing);
        Ok(match base {
            Some(base) => pairs(&tested, failed, &base, limits.as_ref())?,
            None => together(&tested, failed, limits.as_ref())?,
        })
    })
    .await?;

    Ok(Json(body))
}

/// Every play's backtest, over a few threads so the live feed keeps
/// headroom. Plays that can't run come back as `{key, error}`.
fn backtest_all(
    jobs: Vec<(String, bool, StrategyConfig, Arc<Vec<Candle>>)>,
    financing: &crate::engine::financing::FinancingModel,
) -> (Vec<Tested>, Vec<Value>) {
    let run = |(key, exempt, config, bars): &(String, bool, StrategyConfig, Arc<Vec<Candle>>)| {
        let strategy: Strategy = serde_json::from_value(config.parameters.clone())
            .map_err(|e| format!("invalid strategy: {e}"))?;
        let SizingConfig::RiskPct {
            pct,
            max_notional_pct,
        } = strategy.sizing;
        if bars.is_empty() {
            return Err("no history to test on".to_string());
        }
        let trades = run_strategy(bars, config, financing).map_err(|e| e.to_string())?;
        let (from, to) = pipeline::span(bars);
        Ok(Tested {
            play: Play {
                key: key.clone(),
                instrument: config.instrument.clone(),
                risk_pct: pct,
                max_position_pct: max_notional_pct.unwrap_or(MAX_POSITION_PCT_OF_NAV),
                breaker_exempt: *exempt,
                trades,
            },
            granularity: config.granularity,
            from,
            to,
        })
    };

    let per_thread = jobs.len().div_ceil(WORKERS).max(1);
    let results: Vec<(String, Result<Tested, String>)> = std::thread::scope(|scope| {
        jobs.chunks(per_thread)
            .map(|chunk| {
                scope.spawn(move || {
                    chunk
                        .iter()
                        .map(|job| (job.0.clone(), run(job)))
                        .collect::<Vec<_>>()
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .zip(jobs.chunks(per_thread))
            .flat_map(|(handle, chunk)| {
                // A worker that panicked loses its chunk; each of its plays
                // is reported as failed rather than silently missing.
                handle.join().unwrap_or_else(|_| {
                    chunk
                        .iter()
                        .map(|job| (job.0.clone(), Err("its backtest crashed".to_string())))
                        .collect()
                })
            })
            .collect()
    });

    let mut tested = Vec::new();
    let mut failed = Vec::new();
    for (key, result) in results {
        match result {
            Ok(t) => tested.push(t),
            Err(error) => failed.push(json!({ "key": key, "error": error })),
        }
    }
    (tested, failed)
}

/// All plays together over the history they share.
fn together(tested: &[Tested], failed: Vec<Value>, limits: Option<&Limits>) -> AppResult<Value> {
    let (from, to) = shared(tested.iter()).ok_or_else(|| {
        AppError::BadRequest("these strategies share no stretch of history".into())
    })?;

    let alone: Vec<Outcome> = tested
        .iter()
        .map(|t| simulate(&[&t.play], None, from, to))
        .collect();
    let plays: Vec<&Play> = tested.iter().map(|t| &t.play).collect();
    let with_rules = limits.map(|l| simulate(&plays, Some(l), from, to));
    let without_rules = simulate(&plays, None, from, to);

    let correlations: Vec<Vec<Option<f64>>> = alone
        .iter()
        .map(|a| {
            alone
                .iter()
                .map(|b| correlation(&a.daily, &b.daily))
                .collect()
        })
        .collect();

    Ok(json!({
        "from": from,
        "to": to,
        "plays": tested.iter().zip(&alone).map(|(t, a)| json!({
            "key": t.play.key,
            "instrument": t.play.instrument,
            "granularity": t.granularity.as_str(),
            "history_from": t.from,
            "history_to": t.to,
            "alone": a,
        })).collect::<Vec<_>>(),
        "with_rules": with_rules,
        "without_rules": without_rules,
        "correlations": correlations,
        "failed": failed,
    }))
}

/// `base` next to each other play, each pair over the history it shares.
fn pairs(
    tested: &[Tested],
    failed: Vec<Value>,
    base: &str,
    limits: Option<&Limits>,
) -> AppResult<Value> {
    let anchor = tested
        .iter()
        .find(|t| t.play.key == base)
        .ok_or_else(|| AppError::BadRequest(format!("{base} could not be tested")))?;

    let rows: Vec<Value> = tested
        .iter()
        .filter(|t| t.play.key != base)
        .filter_map(|other| {
            let (from, to) = shared([anchor, other].into_iter())?;
            let anchor_alone = simulate(&[&anchor.play], None, from, to);
            let other_alone = simulate(&[&other.play], None, from, to);
            let pair = simulate(&[&anchor.play, &other.play], limits, from, to);
            Some(json!({
                "key": other.play.key,
                "instrument": other.play.instrument,
                "granularity": other.granularity.as_str(),
                "from": from,
                "to": to,
                "correlation": correlation(&anchor_alone.daily, &other_alone.daily),
                "base_alone": lean(anchor_alone),
                "alone": lean(other_alone),
                "pair": lean(pair),
            }))
        })
        .collect();

    Ok(json!({ "base": base, "pairs": rows, "failed": failed }))
}

/// An outcome without its chart points, for long lists.
fn lean(mut outcome: Outcome) -> Outcome {
    outcome.points.clear();
    outcome
}

/// The latest start and earliest end; None when they don't overlap by a
/// month.
fn shared<'a>(tested: impl Iterator<Item = &'a Tested>) -> Option<(DateTime<Utc>, DateTime<Utc>)> {
    let (from, to) = tested.fold(
        (None, None),
        |(from, to): (Option<DateTime<Utc>>, Option<DateTime<Utc>>), t| {
            (
                Some(from.map_or(t.from, |f| f.max(t.from))),
                Some(to.map_or(t.to, |e| e.min(t.to))),
            )
        },
    );
    let (from, to) = (from?, to?);
    (to - from >= chrono::Duration::days(30)).then_some((from, to))
}
