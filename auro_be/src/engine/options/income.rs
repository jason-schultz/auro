//! Premium-selling arithmetic: cash-secured puts and covered calls. These
//! are the numbers a screen ranks on and a backtest books: what the
//! premium yields on the capital it ties up, where the trade breaks even,
//! how likely assignment is, and which strike sits at a target delta.

use super::black_scholes::{d1_d2, norm_cdf, norm_inv};
use super::{Greeks, OptionKind};

/// Shares per standard contract.
pub const CONTRACT_MULTIPLIER: f64 = 100.0;

/// Price below which a cash-secured put loses money at expiry.
pub fn short_put_breakeven(strike: f64, premium: f64) -> f64 {
    strike - premium
}

/// Price below which a covered call loses money at expiry, given the
/// shares' cost basis.
pub fn covered_call_breakeven(cost_basis: f64, premium: f64) -> f64 {
    cost_basis - premium
}

/// Best case for a covered call: called away at `strike`, keeping the
/// premium. As a fraction of the cost basis.
pub fn covered_call_max_return(cost_basis: f64, strike: f64, premium: f64) -> f64 {
    (strike - cost_basis + premium) / cost_basis
}

/// Premium as a fraction of the capital it ties up (the strike for a
/// cash-secured put, the cost basis for a covered call).
pub fn yield_on_capital(premium: f64, capital: f64) -> f64 {
    premium / capital
}

/// [`yield_on_capital`] scaled to a year by calendar days to expiry. The
/// usual way short-dated premium is compared across expiries; it is not a
/// forecast of what a year of rolling would earn.
pub fn annualized_yield(premium: f64, capital: f64, days_to_expiry: f64) -> f64 {
    yield_on_capital(premium, capital) * 365.0 / days_to_expiry.max(1.0)
}

/// Risk-neutral probability the option expires in the money, `N(d2)` for
/// a call and `N(-d2)` for a put. The standard proxy for assignment risk;
/// it ignores early exercise and the drift of the underlying.
pub fn probability_itm(
    kind: OptionKind,
    spot: f64,
    strike: f64,
    t: f64,
    rate: f64,
    div_yield: f64,
    sigma: f64,
) -> Option<f64> {
    if t <= 0.0 || sigma <= 0.0 || spot <= 0.0 || strike <= 0.0 {
        return None;
    }
    let (_, d2) = d1_d2(spot, strike, t, rate, div_yield, sigma);
    Some(match kind {
        OptionKind::Call => norm_cdf(d2),
        OptionKind::Put => norm_cdf(-d2),
    })
}

/// The strike whose Black-Scholes delta equals `target` (positive for
/// calls, negative for puts, magnitude strictly inside 0..1) at the given
/// vol. Inverts delta analytically. A screen then picks the listed strike
/// nearest this price.
pub fn strike_for_delta(
    kind: OptionKind,
    target: f64,
    spot: f64,
    t: f64,
    rate: f64,
    div_yield: f64,
    sigma: f64,
) -> Option<f64> {
    if t <= 0.0 || sigma <= 0.0 || spot <= 0.0 {
        return None;
    }
    let eq = (-div_yield * t).exp();
    let d1 = match kind {
        OptionKind::Call if target > 0.0 && target < eq => norm_inv(target / eq),
        OptionKind::Put if target < 0.0 && -target < eq => -norm_inv(-target / eq),
        _ => return None,
    };
    let vol_t = sigma * t.sqrt();
    Some(spot * ((rate - div_yield + 0.5 * sigma * sigma) * t - d1 * vol_t).exp())
}

/// Sum per-share greeks across legs. `quantity` is contracts, negative
/// when short; the result is in underlying-share terms (×100 per contract).
pub fn net_greeks(legs: &[(Greeks, f64)]) -> Greeks {
    let mut net = Greeks {
        delta: 0.0,
        gamma: 0.0,
        theta: 0.0,
        vega: 0.0,
        rho: 0.0,
    };
    for (g, qty) in legs {
        let scale = qty * CONTRACT_MULTIPLIER;
        net.delta += g.delta * scale;
        net.gamma += g.gamma * scale;
        net.theta += g.theta * scale;
        net.vega += g.vega * scale;
        net.rho += g.rho * scale;
    }
    net
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::options::greeks;

    #[test]
    fn breakevens_and_yields_are_plain_arithmetic() {
        assert_eq!(short_put_breakeven(640.0, 6.4), 633.6);
        assert_eq!(covered_call_breakeven(650.0, 5.0), 645.0);
        assert!((covered_call_max_return(650.0, 660.0, 5.0) - 15.0 / 650.0).abs() < 1e-12);
        assert!((yield_on_capital(6.4, 640.0) - 0.01).abs() < 1e-12);
        // 1% for 30 days ≈ 12.17% annualized.
        assert!((annualized_yield(6.4, 640.0, 30.0) - 0.01 * 365.0 / 30.0).abs() < 1e-12);
        // Zero-day expiry does not divide by zero.
        assert!(annualized_yield(1.0, 100.0, 0.0).is_finite());
    }

    #[test]
    fn probability_itm_is_consistent_between_call_and_put() {
        let (s, k, t, r, q, v) = (650.0, 640.0, 30.0 / 365.0, 0.045, 0.013, 0.18);
        let call = probability_itm(OptionKind::Call, s, k, t, r, q, v).unwrap();
        let put = probability_itm(OptionKind::Put, s, k, t, r, q, v).unwrap();
        assert!((call + put - 1.0).abs() < 1e-12);
        assert!(
            call > 0.5,
            "a put 1.5% OTM should be more likely to expire worthless"
        );
        assert!(probability_itm(OptionKind::Put, s, k, 0.0, r, q, v).is_none());
    }

    #[test]
    fn strike_for_delta_round_trips_through_the_greeks() {
        let (s, t, r, q, v) = (650.0, 30.0 / 365.0, 0.045, 0.013, 0.18);
        for (kind, target) in [
            (OptionKind::Put, -0.30),
            (OptionKind::Put, -0.16),
            (OptionKind::Call, 0.30),
            (OptionKind::Call, 0.05),
        ] {
            let k = strike_for_delta(kind, target, s, t, r, q, v).unwrap();
            let delta = greeks(kind, s, k, t, r, q, v).unwrap().delta;
            assert!(
                (delta - target).abs() < 1e-9,
                "{kind:?} {target}: K={k} delta={delta}"
            );
        }
        // A 30-delta put strikes below spot, a 30-delta call above.
        assert!(strike_for_delta(OptionKind::Put, -0.30, s, t, r, q, v).unwrap() < s);
        assert!(strike_for_delta(OptionKind::Call, 0.30, s, t, r, q, v).unwrap() > s);
        // Wrong-signed or out-of-range targets are rejected.
        assert!(strike_for_delta(OptionKind::Put, 0.30, s, t, r, q, v).is_none());
        assert!(strike_for_delta(OptionKind::Call, 1.5, s, t, r, q, v).is_none());
    }

    #[test]
    fn net_greeks_scale_by_contracts_and_sign() {
        let (s, t, r, q, v) = (650.0, 30.0 / 365.0, 0.045, 0.013, 0.18);
        let put = greeks(OptionKind::Put, s, 630.0, t, r, q, v).unwrap();
        // Short one put: delta positive (we gain as spot rises), theta positive.
        let net = net_greeks(&[(put, -1.0)]);
        assert!((net.delta + put.delta * 100.0).abs() < 1e-12);
        assert!(net.delta > 0.0 && net.theta > 0.0 && net.vega < 0.0);
        // Covered call: long 100 shares is delta 100 outside this helper; the
        // short call leg alone is negative delta.
        let call = greeks(OptionKind::Call, s, 670.0, t, r, q, v).unwrap();
        assert!(net_greeks(&[(call, -2.0)]).delta < 0.0);
    }
}
