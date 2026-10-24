//! "What happens at expiry" for one single-leg position: the numbers a
//! newcomer needs before selling a put or a call, or buying one. Pure: the
//! API layer fills in spot and rate from storage, this module only computes.

use serde::{Deserialize, Serialize};

use super::black_scholes::{greeks, implied_vol, price as model_price, Greeks};
use super::income::{self, CONTRACT_MULTIPLIER};
use super::vol::expected_move;
use super::OptionKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Side {
    Buy,
    Sell,
}

/// The four single-leg shapes the page explains.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Strategy {
    CashSecuredPut,
    CoveredCall,
    LongCall,
    LongPut,
}

impl Strategy {
    pub fn of(kind: OptionKind, side: Side) -> Self {
        match (kind, side) {
            (OptionKind::Put, Side::Sell) => Self::CashSecuredPut,
            (OptionKind::Call, Side::Sell) => Self::CoveredCall,
            (OptionKind::Call, Side::Buy) => Self::LongCall,
            (OptionKind::Put, Side::Buy) => Self::LongPut,
        }
    }
}

/// What the holder is left with at expiry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    /// Short option finished in the money: shares change hands at the strike.
    Assigned,
    /// Short option finished out of the money: premium kept, nothing else.
    ExpiresWorthless,
    /// Long option finished in the money: worth its intrinsic value.
    InTheMoney,
    /// Long option finished out of the money: premium lost.
    Expired,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Input {
    pub kind: OptionKind,
    pub side: Side,
    pub spot: f64,
    pub strike: f64,
    /// Premium per share.
    pub premium: f64,
    pub contracts: f64,
    /// Years to expiry (0 allowed: greeks and probabilities are skipped).
    pub t: f64,
    pub rate: f64,
    pub div_yield: f64,
    /// Annual volatility; None = solve it from the premium.
    pub sigma: Option<f64>,
    /// Covered calls: what the shares cost. None = the spot.
    pub cost_basis: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Scenario {
    pub price: f64,
    /// Change from spot, as a fraction.
    pub change: f64,
    pub outcome: Outcome,
    /// Profit or loss on the whole position in dollars, option leg only for
    /// a cash-secured put / long option, option plus shares for a covered
    /// call measured against the cost basis.
    pub pnl: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Analysis {
    pub strategy: Strategy,
    pub spot: f64,
    pub strike: f64,
    pub premium: f64,
    pub contracts: f64,
    pub shares: f64,
    pub years_to_expiry: f64,
    pub rate: f64,
    pub div_yield: f64,
    /// The volatility used; None when it had to be solved and could not be
    /// (premium below intrinsic, a stale or zero price).
    pub sigma: Option<f64>,
    pub sigma_implied: bool,
    /// Dollars received (sell) or paid (buy) for the whole position.
    pub premium_total: f64,
    /// Dollars set aside: strike × shares for a put, cost basis × shares
    /// for a covered call, the premium for a long option.
    pub capital_required: f64,
    pub yield_on_capital: f64,
    pub annualized_yield: f64,
    pub breakeven: f64,
    /// Best case in dollars; None = unlimited (long call).
    pub max_gain: Option<f64>,
    /// Worst case in dollars, as a positive number.
    pub max_loss: f64,
    /// Chance the option finishes in the money (assignment risk for a
    /// seller, the pay-off case for a buyer). Needs sigma.
    pub probability_itm: Option<f64>,
    /// Chance the position makes money at expiry. Needs sigma.
    pub probability_profit: Option<f64>,
    /// One-standard-deviation move to expiry, in dollars. Needs sigma.
    pub expected_move: Option<f64>,
    /// Position greeks in share terms (already × contracts × 100, signed).
    pub greeks: Option<Greeks>,
    pub scenarios: Vec<Scenario>,
    /// P&L across the price grid at expiry, halfway there and today, for
    /// the payoff chart. Only the expiry curve exists without a volatility.
    pub curves: Vec<Curve>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CurvePoint {
    pub price: f64,
    pub pnl: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Curve {
    pub label: String,
    pub days_to_expiry: f64,
    pub points: Vec<CurvePoint>,
}

/// Price grid for the payoff curves: ±25% in 1% steps.
const CURVE_STEPS: i32 = 25;
const CURVE_STEP: f64 = 0.01;

/// Price grid for the scenario table: ±20% in 2.5% steps, plus the strike
/// and breakeven so the table shows where the outcome flips.
const GRID_STEPS: i32 = 8;
const GRID_STEP: f64 = 0.025;

pub fn analyze(input: &Input) -> Analysis {
    let Input {
        kind,
        side,
        spot,
        strike,
        premium,
        contracts,
        t,
        rate,
        div_yield,
        ..
    } = *input;
    let strategy = Strategy::of(kind, side);
    let shares = contracts * CONTRACT_MULTIPLIER;
    let cost_basis = input.cost_basis.unwrap_or(spot);

    let (sigma, sigma_implied) = match input.sigma {
        Some(s) if s > 0.0 => (Some(s), false),
        _ => (
            implied_vol(kind, premium, spot, strike, t, rate, div_yield),
            true,
        ),
    };

    let premium_total = premium * shares;
    let (capital_required, breakeven, max_gain, max_loss) = match strategy {
        Strategy::CashSecuredPut => (
            strike * shares,
            income::short_put_breakeven(strike, premium),
            Some(premium_total),
            (strike - premium) * shares,
        ),
        Strategy::CoveredCall => (
            cost_basis * shares,
            income::covered_call_breakeven(cost_basis, premium),
            Some((strike - cost_basis + premium) * shares),
            (cost_basis - premium) * shares,
        ),
        Strategy::LongCall => (premium_total, strike + premium, None, premium_total),
        Strategy::LongPut => (
            premium_total,
            strike - premium,
            Some((strike - premium) * shares),
            premium_total,
        ),
    };
    let days = (t * 365.0).max(1.0);
    let yield_on_capital = income::yield_on_capital(premium_total, capital_required);
    let annualized_yield = income::annualized_yield(premium_total, capital_required, days);

    let probability_itm =
        sigma.and_then(|s| income::probability_itm(kind, spot, strike, t, rate, div_yield, s));
    // P(profit) = P(expiry price on the profitable side of breakeven).
    let probability_profit = sigma.and_then(|s| {
        let above =
            income::probability_itm(OptionKind::Call, spot, breakeven, t, rate, div_yield, s)?;
        Some(match strategy {
            Strategy::CashSecuredPut | Strategy::CoveredCall | Strategy::LongCall => above,
            Strategy::LongPut => 1.0 - above,
        })
    });
    let expected = sigma.map(|s| expected_move(spot, s, t));
    let position_greeks = sigma.and_then(|s| {
        let g = greeks(kind, spot, strike, t, rate, div_yield, s)?;
        let qty = match side {
            Side::Buy => contracts,
            Side::Sell => -contracts,
        };
        Some(income::net_greeks(&[(g, qty)]))
    });

    let mut prices: Vec<f64> = (-GRID_STEPS..=GRID_STEPS)
        .map(|i| spot * (1.0 + f64::from(i) * GRID_STEP))
        .chain([strike, breakeven])
        .filter(|p| *p > 0.0)
        .collect();
    prices.sort_by(|a, b| a.partial_cmp(b).expect("finite prices"));
    prices.dedup_by(|a, b| (*a - *b).abs() < 1e-9);
    let scenarios = prices
        .into_iter()
        .map(|price| Scenario {
            price,
            change: price / spot - 1.0,
            outcome: outcome_at(strategy, price, strike),
            pnl: pnl_at(strategy, price, strike, premium, cost_basis, shares),
        })
        .collect();

    let curve_prices: Vec<f64> = (-CURVE_STEPS..=CURVE_STEPS)
        .map(|i| spot * (1.0 + f64::from(i) * CURVE_STEP))
        .filter(|p| *p > 0.0)
        .collect();
    let curve = |label: &str, t_rem: f64| Curve {
        label: label.to_string(),
        days_to_expiry: t_rem * 365.0,
        points: curve_prices
            .iter()
            .map(|&price| CurvePoint {
                price,
                pnl: match sigma {
                    Some(s) if t_rem > 0.0 => mark_to_model(
                        strategy, kind, price, strike, premium, cost_basis, shares, t_rem, rate,
                        div_yield, s,
                    ),
                    _ => pnl_at(strategy, price, strike, premium, cost_basis, shares),
                },
            })
            .collect(),
    };
    let mut curves = vec![curve("expiry", 0.0)];
    if sigma.is_some() && t > 0.0 {
        curves.push(curve("halfway", t / 2.0));
        curves.push(curve("today", t));
    }

    Analysis {
        strategy,
        spot,
        strike,
        premium,
        contracts,
        shares,
        years_to_expiry: t,
        rate,
        div_yield,
        sigma,
        sigma_implied,
        premium_total,
        capital_required,
        yield_on_capital,
        annualized_yield,
        breakeven,
        max_gain,
        max_loss,
        probability_itm,
        probability_profit,
        expected_move: expected,
        greeks: position_greeks,
        scenarios,
        curves,
    }
}

/// Dollar P&L before expiry with the option marked at its model price:
/// what the position would show if closed at `price` with `t_rem` years
/// left. At `t_rem == 0` this equals [`pnl_at`].
#[allow(clippy::too_many_arguments)]
fn mark_to_model(
    strategy: Strategy,
    kind: OptionKind,
    price: f64,
    strike: f64,
    premium: f64,
    cost_basis: f64,
    shares: f64,
    t_rem: f64,
    rate: f64,
    div_yield: f64,
    sigma: f64,
) -> f64 {
    let value = model_price(kind, price, strike, t_rem, rate, div_yield, sigma);
    let per_share = match strategy {
        Strategy::CashSecuredPut => premium - value,
        Strategy::CoveredCall => premium - value + price - cost_basis,
        Strategy::LongCall | Strategy::LongPut => value - premium,
    };
    per_share * shares
}

fn outcome_at(strategy: Strategy, price: f64, strike: f64) -> Outcome {
    let itm = match strategy {
        Strategy::CashSecuredPut | Strategy::LongPut => price < strike,
        Strategy::CoveredCall | Strategy::LongCall => price > strike,
    };
    match (strategy, itm) {
        (Strategy::CashSecuredPut | Strategy::CoveredCall, true) => Outcome::Assigned,
        (Strategy::CashSecuredPut | Strategy::CoveredCall, false) => Outcome::ExpiresWorthless,
        (Strategy::LongCall | Strategy::LongPut, true) => Outcome::InTheMoney,
        (Strategy::LongCall | Strategy::LongPut, false) => Outcome::Expired,
    }
}

/// Dollar P&L at expiry. Shares bought by assignment are valued at the
/// expiry price, so the cash-secured put shows the paper loss on them.
fn pnl_at(
    strategy: Strategy,
    price: f64,
    strike: f64,
    premium: f64,
    cost_basis: f64,
    shares: f64,
) -> f64 {
    let per_share = match strategy {
        Strategy::CashSecuredPut => premium - (strike - price).max(0.0),
        Strategy::CoveredCall => premium + price.min(strike) - cost_basis,
        Strategy::LongCall => (price - strike).max(0.0) - premium,
        Strategy::LongPut => (strike - price).max(0.0) - premium,
    };
    per_share * shares
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(kind: OptionKind, side: Side) -> Input {
        Input {
            kind,
            side,
            spot: 650.0,
            strike: 640.0,
            premium: 6.40,
            contracts: 1.0,
            t: 30.0 / 365.0,
            rate: 0.04,
            div_yield: 0.012,
            sigma: Some(0.18),
            cost_basis: None,
        }
    }

    fn at(a: &Analysis, price: f64) -> &Scenario {
        a.scenarios
            .iter()
            .find(|s| (s.price - price).abs() < 1e-9)
            .unwrap_or_else(|| panic!("no scenario at {price}"))
    }

    #[test]
    fn cash_secured_put_numbers_read_like_the_textbook() {
        let a = analyze(&input(OptionKind::Put, Side::Sell));
        assert_eq!(a.strategy, Strategy::CashSecuredPut);
        assert_eq!(a.premium_total, 640.0);
        assert_eq!(a.capital_required, 64_000.0);
        assert!((a.yield_on_capital - 0.01).abs() < 1e-12);
        assert!((a.breakeven - 633.6).abs() < 1e-9);
        assert_eq!(a.max_gain, Some(640.0));
        assert!((a.max_loss - 63_360.0).abs() < 1e-9);
        // Above the strike: expires worthless, keep the premium.
        let s = at(&a, 650.0);
        assert_eq!((s.outcome, s.pnl), (Outcome::ExpiresWorthless, 640.0));
        // At breakeven: assigned, flat.
        let s = at(&a, 633.6);
        assert_eq!(s.outcome, Outcome::Assigned);
        assert!(s.pnl.abs() < 1e-9);
        // 20% down: assigned, shares worth 520 vs 640 paid, less premium.
        let s = at(&a, 520.0);
        assert!((s.pnl - (640.0 - 120.0 * 100.0)).abs() < 1e-9);
        let p = a.probability_itm.unwrap();
        assert!(p > 0.0 && p < 0.5, "a put 1.5% OTM: {p}");
        assert!(a.probability_profit.unwrap() > 0.5);
        // Short put: positive delta and theta, negative vega.
        let g = a.greeks.unwrap();
        assert!(g.delta > 0.0 && g.theta > 0.0 && g.vega < 0.0);
    }

    #[test]
    fn covered_call_caps_the_upside_at_the_strike() {
        let mut i = input(OptionKind::Call, Side::Sell);
        i.strike = 670.0;
        i.premium = 4.0;
        i.cost_basis = Some(600.0);
        let a = analyze(&i);
        assert_eq!(a.strategy, Strategy::CoveredCall);
        assert_eq!(a.capital_required, 60_000.0);
        assert_eq!(a.breakeven, 596.0);
        // Called away: (670 - 600 + 4) × 100, however far the stock runs.
        assert_eq!(a.max_gain, Some(7_400.0));
        assert_eq!(
            pnl_at(Strategy::CoveredCall, 700.0, 670.0, 4.0, 600.0, 100.0),
            7_400.0
        );
        assert_eq!(
            outcome_at(Strategy::CoveredCall, 700.0, 670.0),
            Outcome::Assigned
        );
        // Below the strike: keep shares and premium, P&L tracks the shares.
        assert_eq!(at(&a, 650.0).outcome, Outcome::ExpiresWorthless);
        assert!((at(&a, 650.0).pnl - 5_400.0).abs() < 1e-9);
    }

    #[test]
    fn long_options_risk_only_the_premium() {
        let mut i = input(OptionKind::Call, Side::Buy);
        i.strike = 660.0;
        i.premium = 5.0;
        let a = analyze(&i);
        assert_eq!(a.strategy, Strategy::LongCall);
        assert_eq!((a.capital_required, a.max_loss), (500.0, 500.0));
        assert_eq!(a.max_gain, None);
        assert_eq!(a.breakeven, 665.0);
        assert_eq!(at(&a, 650.0).outcome, Outcome::Expired);
        assert_eq!(at(&a, 650.0).pnl, -500.0);
        assert_eq!(
            outcome_at(Strategy::LongCall, 680.0, 660.0),
            Outcome::InTheMoney
        );
        assert_eq!(
            pnl_at(Strategy::LongCall, 680.0, 660.0, 5.0, 650.0, 100.0),
            1_500.0
        );

        let mut i = input(OptionKind::Put, Side::Buy);
        i.premium = 5.0;
        let a = analyze(&i);
        assert_eq!(a.max_gain, Some(63_500.0));
        assert_eq!(
            pnl_at(Strategy::LongPut, 600.0, 640.0, 5.0, 650.0, 100.0),
            3_500.0
        );
        assert!(a.probability_profit.unwrap() < 0.5);
    }

    #[test]
    fn sigma_is_solved_from_the_premium_when_not_given() {
        let mut i = input(OptionKind::Put, Side::Sell);
        i.sigma = None;
        let a = analyze(&i);
        assert!(a.sigma_implied);
        let s = a.sigma.expect("solvable premium");
        assert!(s > 0.1 && s < 0.4, "{s}");
        // A premium below intrinsic cannot be a volatility: the rest still
        // computes, the probability fields are simply absent.
        i.premium = 0.01;
        i.strike = 700.0;
        let a = analyze(&i);
        assert!(a.sigma.is_none() && a.probability_itm.is_none() && a.greeks.is_none());
        assert!(a.scenarios.iter().any(|s| s.outcome == Outcome::Assigned));
    }

    #[test]
    fn curves_start_near_zero_today_and_meet_the_expiry_payoff() {
        // Premium at the model's own price, so today's curve is flat at spot.
        let mut i = input(OptionKind::Call, Side::Buy);
        i.premium = model_price(
            OptionKind::Call,
            i.spot,
            i.strike,
            i.t,
            i.rate,
            i.div_yield,
            0.18,
        );
        let a = analyze(&i);

        assert_eq!(
            a.curves
                .iter()
                .map(|c| c.label.as_str())
                .collect::<Vec<_>>(),
            ["expiry", "halfway", "today"]
        );
        let today = a.curves.iter().find(|c| c.label == "today").unwrap();
        let at_spot = today
            .points
            .iter()
            .find(|p| (p.price - i.spot).abs() < 1e-9)
            .unwrap();
        assert!(at_spot.pnl.abs() < 0.01, "today at spot: {}", at_spot.pnl);
        assert!((today.days_to_expiry - 30.0).abs() < 1e-9);

        // Expiry curve is the hockey stick: zero time value, so a deep ITM
        // point equals intrinsic minus premium, per share times 100.
        let expiry = &a.curves[0];
        let deep = expiry.points.last().unwrap();
        let expected = ((deep.price - i.strike).max(0.0) - i.premium) * 100.0;
        assert!((deep.pnl - expected).abs() < 1e-6);
        assert_eq!(expiry.points.len(), 51);
        assert!(expiry.points.windows(2).all(|w| w[0].price < w[1].price));

        // Without a volatility only the expiry curve can be drawn.
        let mut blind = input(OptionKind::Put, Side::Sell);
        blind.sigma = None;
        blind.premium = 0.0001; // too cheap for the solver → no sigma
        let b = analyze(&blind);
        if b.sigma.is_none() {
            assert_eq!(b.curves.len(), 1);
        }
    }

    #[test]
    fn grid_includes_strike_and_breakeven_once_and_is_sorted() {
        let a = analyze(&input(OptionKind::Put, Side::Sell));
        let prices: Vec<f64> = a.scenarios.iter().map(|s| s.price).collect();
        assert!(prices.windows(2).all(|w| w[0] < w[1]));
        assert_eq!(
            prices.iter().filter(|p| (**p - 640.0).abs() < 1e-9).count(),
            1
        );
        assert_eq!(
            prices.iter().filter(|p| (**p - 633.6).abs() < 1e-9).count(),
            1
        );
        assert_eq!(prices.len(), 17 + 2);
    }
}
