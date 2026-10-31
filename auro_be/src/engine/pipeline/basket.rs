//! A recipe tested on several markets at once, as one account: a basket.
//!
//! A basket is a thin wrapper, stored in the config's strategy JSON as
//! `parameters.basket`: the recipe, a list of markets (same timeframe) and
//! a mode.
//!
//! - **together**: the recipe trades every market on its own rules, exactly
//!   as it would on each market alone (`run_strategy`, OANDA financing
//!   included). Live, that's one assignment per market, grouped.
//! - **ranked**: on every `every_bars`-th bar the markets are ranked by a
//!   value one of the recipe's blocks shows and the top ones bought, the
//!   bottom ones sold, until the next rebalance (`engine::rank`). The
//!   recipe's entry and exit rules aren't used; its stop sets each
//!   position's size (an ATR stop sizes every market to the same risk) and
//!   isn't traded, as the papers hold to the rebalance.
//!
//! Either way the trades are replayed on one account by the Together
//! replay (`engine::portfolio::simulate`): live sizing (the recipe's risk
//! per trade against its stop), compounding, no account limits (they're
//! your safety rules, not part of the idea under test). The account is
//! valued at every bar on one clock across the markets, open positions at
//! each market's latest close, so the drawdown sees a position's dip even
//! when it's held for months and recovers. The gates then judge the
//! account: each trade's figure is what it did to the account
//! (`Fill::account_return`), so "trades added up", the per-trade Sharpe
//! and the luck check read the one curve, and both drawdowns are the
//! account's valued one. Monte Carlo redraws the account's daily returns
//! (`Outcome::daily_valued`), as on one market.
//!
//! A ranked basket holds positions across rebalances, so a position kept
//! for years is one "trade": a trade count and a per-trade Sharpe say
//! little about it. It's judged as the papers judge such books, on the
//! account's calendar-month returns (`Outcome::monthly`): the Sharpe, the
//! luck test and the luck check read the months, and a months minimum
//! replaces the trades minimum (`pipeline::months_rules`). Monte Carlo
//! still redraws its days: it needs the path, not the count.
//!
//! Markets join the account when their history starts, so a basket spans
//! from its earliest bar to its latest.

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::PgPool;

use super::{account_sizing, parse_strategy, run_strategy, StrategyConfig};
use crate::db::repositories::candles::load_candles;
use crate::engine::financing::{apply_costs, FinancingModel};
use crate::engine::parallel;
use crate::engine::portfolio::{simulate, Outcome, Play};
use crate::engine::rank::{self, RankRule};
use crate::engine::stats::{stats_with, BacktestStats, Marked};
use crate::engine::strategy::{bounded_window, compute_stop_price, Strategy};
use crate::engine::types::{Candle, Direction, EntryReason, ExitReason, Granularity, Trade};
use crate::error::{AppError, AppResult};

/// Most markets one basket holds.
pub const MAX_MARKETS: usize = 40;

/// Threads one basket's backtests use. The pipeline runs two jobs at once,
/// so two baskets together use four, as one sensitivity grid does.
const THREADS: usize = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Together,
    Ranked,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Basket {
    /// Listed once each, in alphabetical order.
    pub markets: Vec<String>,
    pub mode: Mode,
    /// Ranked baskets only.
    #[serde(default)]
    pub rank: Option<RankRule>,
}

/// The basket's name as one try for the luck check:
/// `"BASKET(A,B,C)@D"`. Other settings on the same markets are the same
/// try, as on one market.
pub fn key<S: AsRef<str>>(markets: &[S], granularity: &str) -> String {
    let names: Vec<&str> = markets.iter().map(AsRef::as_ref).collect();
    format!("BASKET({})@{}", names.join(","), granularity)
}

impl Basket {
    /// The basket in `config`'s strategy JSON, checked; None for a
    /// one-market config. Err says what's wrong in plain words.
    pub fn of(config: &StrategyConfig) -> Result<Option<Basket>, String> {
        let Some(raw) = config.parameters.get("basket") else {
            return Ok(None);
        };
        let basket: Basket = serde_json::from_value(raw.clone())
            .map_err(|e| format!("the basket settings can't be read: {e}"))?;
        basket.check(config.granularity)?;
        Ok(Some(basket))
    }

    fn check(&self, granularity: Granularity) -> Result<(), String> {
        if !matches!(granularity, Granularity::D | Granularity::H4) {
            return Err(format!(
                "a basket is tested on daily or 4-hour bars only, not {granularity}"
            ));
        }
        let n = self.markets.len();
        if n < 2 {
            return Err("a basket needs at least 2 markets".into());
        }
        if n > MAX_MARKETS {
            return Err(format!(
                "a basket holds at most {MAX_MARKETS} markets; this one has {n}"
            ));
        }
        if self.markets.windows(2).any(|w| w[0] >= w[1]) {
            return Err(
                "the basket's markets must be listed once each, in alphabetical order".into(),
            );
        }
        match (self.mode, &self.rank) {
            (Mode::Ranked, Some(rule)) => rule.check(n),
            (Mode::Ranked, None) => Err("a ranked basket needs its ranking settings".into()),
            (Mode::Together, Some(_)) => Err("only a ranked basket takes ranking settings".into()),
            (Mode::Together, None) => Ok(()),
        }
    }
}

/// One market of a basket and its bars.
pub struct Member {
    pub market: String,
    pub candles: Vec<Candle>,
}

/// Every market's bars at `granularity`, those before `before` only when
/// given (the sealed holdout).
pub async fn load(
    pool: &PgPool,
    basket: &Basket,
    granularity: Granularity,
    before: Option<DateTime<Utc>>,
) -> AppResult<Vec<Member>> {
    let mut members = Vec::with_capacity(basket.markets.len());
    for market in &basket.markets {
        let candles = load_candles(pool, market, granularity)
            .await
            .map_err(AppError::Database)?
            .into_iter()
            .filter(|c| before.is_none_or(|b| c.time < b))
            .collect();
        members.push(Member {
            market: market.clone(),
            candles,
        });
    }
    Ok(members)
}

/// The markets with no bar `has` accepts, or None when every one has one.
pub fn missing(members: &[Member], has: impl Fn(&Candle) -> bool) -> Option<Vec<&str>> {
    let missing: Vec<&str> = members
        .iter()
        .filter(|m| !m.candles.iter().any(&has))
        .map(|m| m.market.as_str())
        .collect();
    (!missing.is_empty()).then_some(missing)
}

/// The bars a run uses.
#[derive(Debug, Clone, Copy)]
pub enum Window {
    Whole,
    /// Bars before this moment (the walk-forward's in-sample part).
    Before(DateTime<Utc>),
    /// Every bar, so blocks (and a ranking's look-back) warm up on
    /// history, but only trades entered from this moment on count: the
    /// walk-forward's out-of-sample part and the holdout. A ranking
    /// rebalances from this moment on, as a book started then would.
    Counting(DateTime<Utc>),
}

impl Window {
    fn bars(self, candles: &[Candle]) -> &[Candle] {
        match self {
            Window::Whole | Window::Counting(_) => candles,
            Window::Before(at) => &candles[..candles.partition_point(|c| c.time < at)],
        }
    }
}

/// The moment 70% of the way through the basket's history: the
/// walk-forward's split, as on one market (by time here, since the
/// markets' bars don't line up).
pub fn split_at(members: &[Member]) -> Option<DateTime<Utc>> {
    let (from, to) = span(members.iter().map(|m| m.candles.as_slice()))?;
    Some(from + (to - from) * 7 / 10)
}

/// Earliest first bar to latest last bar.
fn span<'a>(bars: impl Iterator<Item = &'a [Candle]>) -> Option<(DateTime<Utc>, DateTime<Utc>)> {
    bars.filter_map(|b| Some((b.first()?.time, b.last()?.time)))
        .reduce(|(f, t), (f2, t2)| (f.min(f2), t.max(t2)))
}

/// A basket's run on one account.
pub struct Run {
    /// Judged as one market's are; the account figures are the account's.
    /// A ranked basket's are judged by months
    /// (`BacktestStats::judge_by_months`).
    pub stats: BacktestStats,
    /// Every trade taken, in the order it closed, its return being what it
    /// did to the account.
    pub trades: Vec<Trade>,
    pub outcome: Outcome,
    pub from: DateTime<Utc>,
    pub to: DateTime<Utc>,
}

/// The basket over `window` with `config`'s recipe (its parameters may be
/// a nearby setting's), replayed on one account.
pub fn run(
    members: &[Member],
    basket: &Basket,
    config: &StrategyConfig,
    financing: &FinancingModel,
    window: Window,
) -> Result<Run, String> {
    let bars: Vec<(&str, &[Candle])> = members
        .iter()
        .map(|m| (m.market.as_str(), window.bars(&m.candles)))
        .collect();
    let (first, to) =
        span(bars.iter().map(|(_, b)| *b)).ok_or("no bars to test on in this stretch")?;
    let from = match window {
        Window::Counting(at) => at,
        _ => first,
    };

    let mut per_market = match (&basket.mode, &basket.rank) {
        (Mode::Ranked, Some(rule)) => {
            let start = match window {
                Window::Counting(at) => Some(at),
                _ => None,
            };
            ranked_trades(&bars, rule, config, financing, start)?
        }
        _ => together_trades(&bars, config, financing)?,
    };
    if let Window::Counting(at) = window {
        for trades in &mut per_market {
            trades.retain(|t| t.entry_time >= at);
        }
    }

    let sizing = account_sizing(config).map_err(|e| e.to_string())?;
    let plays: Vec<Play> = bars
        .iter()
        .zip(per_market)
        .map(|((market, candles), trades)| Play {
            key: market.to_string(),
            instrument: market.to_string(),
            risk_pct: sizing.risk_pct,
            max_position_pct: sizing.max_position_pct,
            breaker_exempt: true,
            trades,
            bars: candles,
        })
        .collect();
    let outcome = simulate(&plays.iter().collect::<Vec<_>>(), None, from, to);

    let trades: Vec<Trade> = outcome
        .fills
        .iter()
        .map(|f| Trade {
            pnl_percent: f.account_return,
            ..f.trade
        })
        .collect();
    // The account compounds what the trades did to it; the trades already
    // carry their size, so they aren't sized again. Both drawdowns are the
    // account's, valued every bar.
    let marked = Marked {
        max_drawdown: -outcome.max_drawdown,
        account_return: outcome.total_return,
        account_max_drawdown: -outcome.max_drawdown,
        annual_sharpe: outcome.annual_sharpe,
    };
    let mut stats = stats_with(&trades, sizing, marked);
    if basket.mode == Mode::Ranked {
        stats.judge_by_months(&outcome.monthly);
    }
    Ok(Run {
        stats,
        trades,
        outcome,
        from,
        to,
    })
}

impl Run {
    /// The returns its stages judge: each trade's (what it did to the
    /// account) or, judged by months (ranked), each calendar month's.
    pub fn returns(&self) -> Vec<f64> {
        match self.stats.num_months {
            Some(_) => self.outcome.monthly.clone(),
            None => self.trades.iter().map(|t| t.pnl_percent).collect(),
        }
    }
}

/// `config` for one market of the basket: the recipe on that instrument.
fn member_config(config: &StrategyConfig, market: &str) -> StrategyConfig {
    let mut parameters = config.parameters.clone();
    if let Some(object) = parameters.as_object_mut() {
        object.insert("instrument".into(), Value::String(market.to_string()));
        object.remove("basket");
    }
    StrategyConfig {
        instrument: market.to_string(),
        parameters,
        ..config.clone()
    }
}

/// Each market traded on the recipe's own rules, as it would be alone.
fn together_trades(
    bars: &[(&str, &[Candle])],
    config: &StrategyConfig,
    financing: &FinancingModel,
) -> Result<Vec<Vec<Trade>>, String> {
    let results = parallel::map(
        bars,
        THREADS,
        |(market, candles)| {
            if candles.is_empty() {
                return Ok(Vec::new());
            }
            run_strategy(candles, &member_config(config, market), financing)
                .map_err(|e| format!("{market}: {e}"))
        },
        |(market, _)| Err(format!("{market}: its backtest crashed")),
    );
    let (ok, failed): (Vec<_>, Vec<_>) = results.into_iter().partition(Result::is_ok);
    if !failed.is_empty() {
        let why: Vec<String> = failed.into_iter().filter_map(Result::err).collect();
        return Err(why.join("; "));
    }
    Ok(ok.into_iter().filter_map(Result::ok).collect())
}

/// A ranked position while it's held.
struct Holding {
    direction: Direction,
    entry_price: f64,
    entry_time: DateTime<Utc>,
    stop_price: f64,
    score: f64,
}

impl Holding {
    fn close(self, bar: &Candle, exit_reason: ExitReason) -> Trade {
        let exit_price = bar.exit_fill_price(self.direction);
        let pnl_percent = match self.direction {
            Direction::Long => (exit_price - self.entry_price) / self.entry_price,
            Direction::Short => (self.entry_price - exit_price) / self.entry_price,
        };
        Trade {
            direction: self.direction,
            entry_price: self.entry_price,
            exit_price,
            entry_time: self.entry_time,
            exit_time: bar.time,
            pnl_percent,
            entry_reason: EntryReason::Indicator {
                name: "rank_score",
                value: self.score,
            },
            exit_reason,
            stop_price: self.stop_price,
        }
    }
}

/// The ranked basket's trades per market. The clock is the bars the
/// markets share (`rank::rebalance_slot`); a moment counts as a bar when at
/// least half the markets trading then have one, so one market's odd
/// holiday bar doesn't move the schedule. Every `every_bars`-th one is a
/// rebalance: each market with a bar then is scored, `rank::targets`
/// decides, and a market whose target changed closes at that bar's close
/// and opens the new side there. A market without a bar keeps what it
/// holds. Whatever is still held closes at the market's last bar.
fn ranked_trades(
    bars: &[(&str, &[Candle])],
    rule: &RankRule,
    config: &StrategyConfig,
    financing: &FinancingModel,
    start: Option<DateTime<Utc>>,
) -> Result<Vec<Vec<Trade>>, String> {
    let (block, value) = rule
        .source()
        .ok_or_else(|| format!("the ranking can't read {:?}", rule.by))?;
    let strategies: Vec<Strategy> = bars
        .iter()
        .map(|(market, _)| {
            parse_strategy(&member_config(config, market).parameters, financing)
                .map_err(|e| format!("{market}: {e}"))
        })
        .collect::<Result<_, _>>()?;
    if strategies
        .first()
        .is_none_or(|s| !s.components.contains_key(block))
    {
        return Err(format!(
            "the ranking reads block \"{block}\", which the recipe doesn't have"
        ));
    }
    let granularity = config.granularity;
    let cap = granularity.buffer_capacity();

    // Slot → (market, bar) for every market with a bar there, the later
    // bar when one market has two.
    let mut slots: BTreeMap<i64, Vec<(usize, usize)>> = BTreeMap::new();
    for (m, (_, candles)) in bars.iter().enumerate() {
        for (i, c) in candles.iter().enumerate() {
            let slot = slots
                .entry(rank::rebalance_slot(c.time, granularity))
                .or_default();
            match slot.last_mut() {
                Some(last) if last.0 == m => last.1 = i,
                _ => slot.push((m, i)),
            }
        }
    }
    let spans: Vec<(i64, i64)> = bars
        .iter()
        .filter_map(|(_, c)| {
            Some((
                rank::rebalance_slot(c.first()?.time, granularity),
                rank::rebalance_slot(c.last()?.time, granularity),
            ))
        })
        .collect();
    let clock = slots.into_iter().filter(|(slot, present)| {
        let trading = spans
            .iter()
            .filter(|(first, last)| first <= slot && slot <= last)
            .count();
        present.len() * 2 >= trading
            // Rebalances from `start` on; the bars before it only warm the
            // ranking up.
            && start.is_none_or(|at| present.iter().all(|&(m, i)| bars[m].1[i].time >= at))
    });

    let mut held: Vec<Option<Holding>> = bars.iter().map(|_| None).collect();
    let mut trades: Vec<Vec<Trade>> = bars.iter().map(|_| Vec::new()).collect();
    let mut scored_any = false;
    for (_, present) in clock.step_by(rule.every_bars) {
        let scores: Vec<(&str, Option<f64>)> = present
            .iter()
            .map(|&(m, i)| {
                let window = bounded_window(bars[m].1, i, cap);
                let score = strategies[m]
                    .components
                    .get(block)
                    .and_then(|c| c.series(window).get(value).copied());
                (bars[m].0, score)
            })
            .collect();
        scored_any |= scores.iter().any(|(_, s)| s.is_some());
        let Some(targets) = rank::targets(&scores, rule) else {
            continue;
        };
        for (&(m, i), (_, score)) in present.iter().zip(&scores) {
            let (market, candles) = bars[m];
            let want = targets.iter().find(|(t, _)| t == market).map(|(_, d)| *d);
            if held[m].as_ref().map(|h| h.direction) == want {
                continue;
            }
            let bar = &candles[i];
            if let Some(h) = held[m].take() {
                trades[m].push(h.close(bar, ExitReason::TrendReversal));
            }
            let Some(direction) = want else { continue };
            let entry_price = bar.entry_fill_price(direction);
            let window = bounded_window(candles, i, cap);
            // No stop, no size: the market sits this period out.
            if let Some(stop_price) =
                compute_stop_price(&strategies[m], entry_price, direction, window)
            {
                held[m] = Some(Holding {
                    direction,
                    entry_price,
                    entry_time: bar.time,
                    stop_price,
                    score: score.unwrap_or(0.0),
                });
            }
        }
    }
    if !scored_any && bars.iter().any(|(_, c)| !c.is_empty()) {
        return Err(format!(
            "block \"{block}\" never showed a value called \"{value}\" on these bars (a wrong name, or too little history to work it out)"
        ));
    }

    for (m, h) in held.into_iter().enumerate() {
        if let (Some(h), Some(last)) = (h, bars[m].1.last()) {
            trades[m].push(h.close(last, ExitReason::EndOfData));
        }
    }
    for ((market, _), t) in bars.iter().zip(&mut trades) {
        apply_costs(t, market, financing);
    }
    Ok(trades)
}

/// The basket's part of a stage's stats, for the results page: what was
/// tested, each market's share of the result, and the account's curve.
pub fn stats_json(basket: &Basket, granularity: Granularity, run: &Run) -> Value {
    let mut by_market: BTreeMap<&str, (usize, usize, f64)> = basket
        .markets
        .iter()
        .map(|m| (m.as_str(), (0, 0, 0.0)))
        .collect();
    for fill in &run.outcome.fills {
        if let Some(row) = by_market.get_mut(fill.key.as_str()) {
            row.0 += 1;
            row.1 += usize::from(fill.account_return > 0.0);
            row.2 += fill.account_return;
        }
    }
    json!({
        "key": key(&basket.markets, granularity.as_str()),
        "mode": basket.mode,
        "rank": basket.rank,
        "markets": basket.markets.len(),
        "from": run.from,
        "to": run.to,
        "annual_return": run.outcome.annual_return,
        "by_market": by_market.into_iter().map(|(market, (trades, wins, sum))| json!({
            "market": market,
            "trades": trades,
            "wins": wins,
            // What its trades added to the account, as shares of it.
            "account_return": sum,
        })).collect::<Vec<_>>(),
        "curve": run.outcome.points,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, TimeZone};
    use uuid::Uuid;

    use crate::engine::types::OHLC;

    fn bars(start: DateTime<Utc>, closes: &[f64]) -> Vec<Candle> {
        closes
            .iter()
            .enumerate()
            .map(|(i, &c)| Candle {
                time: start + Duration::days(i as i64),
                mid: OHLC {
                    open: c,
                    high: c,
                    low: c,
                    close: c,
                },
                volume: 1,
                bid: None,
                ask: None,
            })
            .collect()
    }

    fn day(d: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2024, 1, d, 22, 0, 0).unwrap()
    }

    /// A momentum recipe: buy on an up 3-bar return, sell on a down one,
    /// a 10% stop, 1% risk. Ranked baskets read `mom.roc`.
    fn config(basket: Value) -> StrategyConfig {
        StrategyConfig {
            id: Uuid::nil(),
            instrument: "AAA".into(),
            granularity: Granularity::D,
            strategy_type: "composite".into(),
            parameters: json!({
                "version": "1", "instrument": "AAA", "granularity": "D",
                "components": {"mom": {"type": "Momentum", "params": {"lookback": 3}}},
                "entry": {"long": "mom.up", "short": "mom.down"},
                "exit": {"long": "mom.down", "short": "mom.up"},
                "stop": {"type": "FixedPct", "params": {"pct": -0.1}},
                "sizing": {"type": "RiskPct", "params": {"pct": 0.01}},
                "basket": basket,
            }),
        }
    }

    fn members(series: &[(&str, Vec<f64>)]) -> Vec<Member> {
        series
            .iter()
            .map(|(m, closes)| Member {
                market: m.to_string(),
                candles: bars(day(1), closes),
            })
            .collect()
    }

    #[test]
    fn a_basket_is_checked_in_plain_words() {
        let of = |basket: Value| Basket::of(&config(basket));
        assert!(of(json!({"markets": ["AAA", "BBB"], "mode": "together"}))
            .unwrap()
            .is_some());
        let err = |basket: Value| of(basket).unwrap_err();
        assert!(err(json!({"markets": ["AAA"], "mode": "together"})).contains("at least 2"));
        assert!(
            err(json!({"markets": ["BBB", "AAA"], "mode": "together"})).contains("alphabetical")
        );
        let many: Vec<String> = (0..41).map(|i| format!("M{i:02}")).collect();
        assert!(err(json!({"markets": many, "mode": "together"})).contains("at most 40"));
        assert!(
            err(json!({"markets": ["AAA", "BBB"], "mode": "ranked"})).contains("ranking settings")
        );
        let h1 = StrategyConfig {
            granularity: Granularity::H1,
            ..config(json!({"markets": ["AAA", "BBB"], "mode": "together"}))
        };
        assert!(Basket::of(&h1).unwrap_err().contains("daily or 4-hour"));
        // One market: no basket.
        let mut single = config(Value::Null);
        single.parameters.as_object_mut().unwrap().remove("basket");
        assert_eq!(Basket::of(&single).unwrap(), None);
    }

    #[test]
    fn the_key_names_every_market_and_the_timeframe() {
        assert_eq!(key(&["AAA", "BBB"], "D"), "BASKET(AAA,BBB)@D");
    }

    #[test]
    fn together_each_market_trades_its_own_rules_on_one_account() {
        let raw = json!({"markets": ["AAA", "BBB"], "mode": "together"});
        let config = config(raw);
        let basket = Basket::of(&config).unwrap().unwrap();
        let up: Vec<f64> = (0..20).map(|i| 100.0 + i as f64).collect();
        let down: Vec<f64> = (0..20).map(|i| 100.0 - i as f64).collect();
        let members = members(&[("AAA", up), ("BBB", down)]);
        let run = run(
            &members,
            &basket,
            &config,
            &FinancingModel::default(),
            Window::Whole,
        )
        .unwrap();

        // Each market alone: one trade, held to the end, each a winner.
        assert_eq!(run.trades.len(), 2);
        assert!(run.trades.iter().all(|t| t.pnl_percent > 0.0));
        // Each trade's figure is what it did to the account: a 10% stop at
        // 1% risk takes a tenth of the account, so far less than the move.
        // (the first to close, on an untouched account).
        let first = &run.outcome.fills[0];
        assert_eq!(first.key, "AAA");
        assert!((run.trades[0].pnl_percent - 0.1 * first.trade.pnl_percent).abs() < 1e-12);
        assert!(run.trades[0].pnl_percent < first.trade.pnl_percent);
        assert!((run.stats.account_return - run.outcome.total_return).abs() < 1e-12);

        // Both drawdowns are the account's, valued every bar.
        assert_eq!(run.stats.max_drawdown, -run.outcome.max_drawdown);
        assert_eq!(run.stats.account_max_drawdown, -run.outcome.max_drawdown);
        // Judged on its trades, not months.
        assert_eq!(run.stats.num_months, None);
        assert_eq!(run.returns().len(), 2);

        let json = stats_json(&basket, Granularity::D, &run);
        assert_eq!(json["key"], "BASKET(AAA,BBB)@D");
        assert_eq!(json["by_market"][0]["market"], "AAA");
        assert_eq!(json["by_market"][0]["trades"], 1);
    }

    #[test]
    fn the_walk_forward_halves_split_by_time() {
        let members = members(&[("AAA", vec![1.0; 10]), ("BBB", vec![1.0; 20])]);
        // 70% of 19 days after the first bar.
        let at = split_at(&members).unwrap();
        assert_eq!(at, day(1) + Duration::days(19) * 7 / 10);
        assert_eq!(Window::Before(at).bars(&members[0].candles).len(), 10);
        // The unseen part runs on every bar, counting from the split.
        assert_eq!(Window::Counting(at).bars(&members[1].candles).len(), 20);
    }

    #[test]
    fn a_ranking_counted_from_the_split_starts_warm_and_rebalances_from_there() {
        let raw = json!({"markets": ["AAA", "BBB", "CCC"], "mode": "ranked",
            "rank": {"by": "mom.roc", "every_bars": 5, "long_top": 1, "short_bottom": 1}});
        let config = config(raw);
        let basket = Basket::of(&config).unwrap().unwrap();
        let up: Vec<f64> = (0..28).map(|i| 100.0 + i as f64).collect();
        let down: Vec<f64> = (0..28).map(|i| 100.0 - i as f64).collect();
        let members = members(&[("AAA", up), ("BBB", vec![100.0; 28]), ("CCC", down)]);
        let run = run(
            &members,
            &basket,
            &config,
            &FinancingModel::default(),
            Window::Counting(day(20)),
        )
        .unwrap();

        // The 3-bar return is already known on the split day (warmed on the
        // bars before it), so the book opens there, not a rebalance later;
        // the position held since day 6 isn't counted.
        let entries: Vec<_> = run
            .outcome
            .fills
            .iter()
            .map(|f| (f.key.as_str(), f.trade.direction, f.trade.entry_time))
            .collect();
        assert_eq!(
            entries,
            vec![
                ("AAA", Direction::Long, day(20)),
                ("CCC", Direction::Short, day(20))
            ]
        );
    }

    #[test]
    fn ranked_holds_the_leader_long_and_the_laggard_short_until_the_rebalance() {
        let raw = json!({"markets": ["AAA", "BBB", "CCC"], "mode": "ranked",
            "rank": {"by": "mom.roc", "every_bars": 5, "long_top": 1, "short_bottom": 1}});
        let config = config(raw);
        let basket = Basket::of(&config).unwrap().unwrap();
        // AAA rises, CCC falls, BBB flat: a 3-bar return needs 4 bars, so
        // the first rebalance (bar 0) has no scores; bar 5 ranks.
        let up: Vec<f64> = (0..12).map(|i| 100.0 + i as f64).collect();
        let down: Vec<f64> = (0..12).map(|i| 100.0 - i as f64).collect();
        let members = members(&[("AAA", up), ("BBB", vec![100.0; 12]), ("CCC", down)]);
        let run = run(
            &members,
            &basket,
            &config,
            &FinancingModel::default(),
            Window::Whole,
        )
        .unwrap();

        let by_market = |m: &str| {
            run.outcome
                .fills
                .iter()
                .filter(|f| f.key == m)
                .map(|f| (f.trade.direction, f.trade.entry_time, f.trade.exit_time))
                .collect::<Vec<_>>()
        };
        // Bar 5 opens them, bar 10 keeps them (same ranks), the last bar
        // closes them.
        assert_eq!(by_market("AAA"), vec![(Direction::Long, day(6), day(12))]);
        assert_eq!(by_market("CCC"), vec![(Direction::Short, day(6), day(12))]);
        assert!(by_market("BBB").is_empty());
    }

    #[test]
    fn a_ranking_on_a_value_the_block_never_shows_fails_loudly() {
        let raw = json!({"markets": ["AAA", "BBB"], "mode": "ranked",
            "rank": {"by": "mom.nope", "every_bars": 2, "long_top": 1, "short_bottom": 1}});
        let config = config(raw);
        let basket = Basket::of(&config).unwrap().unwrap();
        let members = members(&[("AAA", vec![1.0; 10]), ("BBB", vec![1.0; 10])]);
        let err = run(
            &members,
            &basket,
            &config,
            &FinancingModel::default(),
            Window::Whole,
        )
        .err()
        .unwrap();
        assert!(err.contains("\"nope\""), "{err}");

        let missing_block = json!({"markets": ["AAA", "BBB"], "mode": "ranked",
            "rank": {"by": "carry.carry", "every_bars": 2, "long_top": 1, "short_bottom": 1}});
        let config = super::tests::config(missing_block);
        let basket = Basket::of(&config).unwrap().unwrap();
        let err = run(
            &members,
            &basket,
            &config,
            &FinancingModel::default(),
            Window::Whole,
        )
        .err()
        .unwrap();
        assert!(err.contains("doesn't have"), "{err}");
    }

    #[test]
    fn the_holdout_counts_only_trades_entered_in_it() {
        let raw = json!({"markets": ["AAA", "BBB"], "mode": "together"});
        let config = config(raw);
        let basket = Basket::of(&config).unwrap().unwrap();
        let up: Vec<f64> = (0..20).map(|i| 100.0 + i as f64).collect();
        let members = members(&[("AAA", up.clone()), ("BBB", up)]);
        let run = run(
            &members,
            &basket,
            &config,
            &FinancingModel::default(),
            Window::Counting(day(10)),
        )
        .unwrap();
        // Both trades opened on day 4, before the holdout.
        assert!(run.trades.is_empty());
        assert_eq!(run.from, day(10));
        assert!(missing(&members, |c| c.time >= day(25)).is_some());
        assert!(missing(&members, |c| c.time >= day(10)).is_none());
    }

    #[test]
    fn a_ranked_basket_is_judged_on_its_calendar_months() {
        let raw = json!({"markets": ["AAA", "BBB", "CCC"], "mode": "ranked",
            "rank": {"by": "mom.roc", "every_bars": 5, "long_top": 1, "short_bottom": 1}});
        let config = config(raw);
        let basket = Basket::of(&config).unwrap().unwrap();
        // 120 daily bars from Jan 1 2024: Jan to Apr 29. AAA rises and CCC
        // falls with a wobble, so the months differ.
        let wobble = |i: usize| 3.0 * ((i as f64) / 4.0).sin();
        let up: Vec<f64> = (0..120).map(|i| 100.0 + i as f64 + wobble(i)).collect();
        let down: Vec<f64> = (0..120).map(|i| 300.0 - i as f64 + wobble(i)).collect();
        let members = members(&[("AAA", up), ("BBB", vec![100.0; 120]), ("CCC", down)]);
        let run = run(
            &members,
            &basket,
            &config,
            &FinancingModel::default(),
            Window::Whole,
        )
        .unwrap();

        // Held from the first scored rebalance (Jan 6) to the last bar:
        // two "trades", four months.
        assert_eq!(run.stats.num_trades, 2);
        assert_eq!(run.stats.num_months, Some(4));
        let months = run.returns();
        assert_eq!(months, run.outcome.monthly);
        assert_eq!(months.len(), 4);
        // The months compound to the account's return.
        let grown = months.iter().fold(1.0, |nav, r| nav * (1.0 + r)) - 1.0;
        assert!((grown - run.outcome.total_return).abs() < 1e-9);
        // Sharpe and the annual Sharpe are the months'.
        let n = 4.0;
        let mean = months.iter().sum::<f64>() / n;
        let sd = (months.iter().map(|m| (m - mean).powi(2)).sum::<f64>() / n).sqrt();
        assert!((run.stats.sharpe_ratio - mean / sd).abs() < 1e-12);
        assert!((run.stats.annual_sharpe - mean / sd * 12f64.sqrt()).abs() < 1e-12);

        // Monte Carlo redraws its days, not its months.
        assert_monte_carlo_reads_the_daily_account(&run);
    }

    /// The account's daily returns compound to its growth, and Monte Carlo
    /// redraws them (`pipeline::run_monte_carlo_sims`).
    fn assert_monte_carlo_reads_the_daily_account(run: &Run) {
        let days = &run.outcome.daily_valued;
        assert!(days.len() > 20, "{} days", days.len());
        let grown = days.iter().fold(1.0, |nav, r| nav * (1.0 + r)) - 1.0;
        assert!((grown - run.outcome.total_return).abs() < 1e-9);
        let mut rng = <rand::rngs::StdRng as rand::SeedableRng>::seed_from_u64(1);
        let mc = super::super::run_monte_carlo_sims(days, &run.outcome.daily_lows, &mut rng);
        assert_eq!(mc["mc_method"], "daily_block_bootstrap");
        assert_eq!(mc["num_days"], days.len());
        let dd = mc["p95_drawdown"].as_f64().unwrap();
        assert!((0.0..1.0).contains(&dd));
    }

    #[test]
    fn a_together_basket_runs_monte_carlo_on_its_daily_account() {
        let raw = json!({"markets": ["AAA", "BBB"], "mode": "together"});
        let config = config(raw);
        let basket = Basket::of(&config).unwrap().unwrap();
        let wobble = |i: usize| 4.0 * ((i as f64) / 3.0).sin();
        let a: Vec<f64> = (0..60)
            .map(|i| 100.0 + i as f64 * 0.5 + wobble(i))
            .collect();
        let b: Vec<f64> = (0..60)
            .map(|i| 100.0 - i as f64 * 0.3 + wobble(i + 2))
            .collect();
        let members = members(&[("AAA", a), ("BBB", b)]);
        let run = run(
            &members,
            &basket,
            &config,
            &FinancingModel::default(),
            Window::Whole,
        )
        .unwrap();
        assert!(!run.trades.is_empty());
        assert_monte_carlo_reads_the_daily_account(&run);
        // Its dips while positions are open show in the redrawn paths.
        assert!(run.outcome.daily_valued.iter().any(|r| *r < 0.0));
    }
}
