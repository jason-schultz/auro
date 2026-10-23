use std::f64::consts::{PI, SQRT_2};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OptionKind {
    Call,
    Put,
}

impl OptionKind {
    /// The vendor's `contract_type` string.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "call" | "C" | "c" => Some(Self::Call),
            "put" | "P" | "p" => Some(Self::Put),
            _ => None,
        }
    }
}

/// Per-share greeks. `theta` is per calendar year (divide by 365 for a daily
/// decay); `vega` and `rho` are per unit of volatility / rate (divide by 100
/// for the per-point figures brokers show).
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize)]
pub struct Greeks {
    pub delta: f64,
    pub gamma: f64,
    pub theta: f64,
    pub vega: f64,
    pub rho: f64,
}

/// Standard normal density.
pub fn norm_pdf(x: f64) -> f64 {
    (-0.5 * x * x).exp() / (2.0 * PI).sqrt()
}

/// Standard normal CDF via the complementary error function.
pub fn norm_cdf(x: f64) -> f64 {
    0.5 * erfc(-x / SQRT_2)
}

/// Complementary error function, W. J. Cody's rational Chebyshev
/// approximation (relative error below 1e-15 on the real line). Pulled in by
/// hand rather than adding a numerics crate for one function; the published
/// coefficients carry more digits than f64 holds, kept verbatim.
#[allow(clippy::excessive_precision)]
fn erfc(x: f64) -> f64 {
    let ax = x.abs();
    let result = if ax < 0.5 {
        // erf on |x| < 0.5
        const A: [f64; 5] = [
            3.16112374387056560e00,
            1.13864154151050156e02,
            3.77485237685302021e02,
            3.20937758913846947e03,
            1.85777706184602653e-01,
        ];
        const B: [f64; 4] = [
            2.36012909523441209e01,
            2.44024637934444173e02,
            1.28261652607737228e03,
            2.84423683343917062e03,
        ];
        let z = ax * ax;
        let mut xnum = A[4] * z;
        let mut xden = z;
        for i in 0..3 {
            xnum = (xnum + A[i]) * z;
            xden = (xden + B[i]) * z;
        }
        let erf = ax * (xnum + A[3]) / (xden + B[3]);
        1.0 - erf
    } else if ax <= 4.0 {
        const C: [f64; 9] = [
            5.64188496988670089e-01,
            8.88314979438837594e00,
            6.61191906371416295e01,
            2.98635138197400131e02,
            8.81952221241769090e02,
            1.71204761263407058e03,
            2.05107837782607147e03,
            1.23033935479799725e03,
            2.15311535474403846e-08,
        ];
        const D: [f64; 8] = [
            1.57449261107098347e01,
            1.17693950891312499e02,
            5.37181101862009858e02,
            1.62138957456669019e03,
            3.29079923573345963e03,
            4.36261909014324716e03,
            3.43936767414372164e03,
            1.23033935480374942e03,
        ];
        let mut xnum = C[8] * ax;
        let mut xden = ax;
        for i in 0..7 {
            xnum = (xnum + C[i]) * ax;
            xden = (xden + D[i]) * ax;
        }
        let r = (xnum + C[7]) / (xden + D[7]);
        let z = (ax * 16.0).trunc() / 16.0;
        let del = (ax - z) * (ax + z);
        (-z * z).exp() * (-del).exp() * r
    } else {
        const P: [f64; 6] = [
            3.05326634961232344e-01,
            3.60344899949804439e-01,
            1.25781726111229246e-01,
            1.60837851487422766e-02,
            6.58749161529837803e-04,
            1.63153871373020978e-02,
        ];
        const Q: [f64; 5] = [
            2.56852019228982242e00,
            1.87295284992346047e00,
            5.27905102951428412e-01,
            6.05183413124413191e-02,
            2.33520497626869185e-03,
        ];
        if ax >= 26.0 {
            0.0
        } else {
            let z = 1.0 / (ax * ax);
            let mut xnum = P[5] * z;
            let mut xden = z;
            for i in 0..4 {
                xnum = (xnum + P[i]) * z;
                xden = (xden + Q[i]) * z;
            }
            let mut r = z * (xnum + P[4]) / (xden + Q[4]);
            r = (1.0 / PI.sqrt() - r) / ax;
            let zz = (ax * 16.0).trunc() / 16.0;
            let del = (ax - zz) * (ax + zz);
            (-zz * zz).exp() * (-del).exp() * r
        }
    };
    if x < 0.0 {
        2.0 - result
    } else {
        result
    }
}

/// Inverse of [`norm_cdf`] on (0, 1): Acklam's rational approximation
/// refined with one Halley step through `erfc`, accurate to ~1e-15.
/// Returns ±infinity at 0 and 1 and NaN outside.
pub fn norm_inv(p: f64) -> f64 {
    if !(0.0..=1.0).contains(&p) {
        return f64::NAN;
    }
    if p == 0.0 {
        return f64::NEG_INFINITY;
    }
    if p == 1.0 {
        return f64::INFINITY;
    }
    const A: [f64; 6] = [
        -3.969683028665376e+01,
        2.209460984245205e+02,
        -2.759285104469687e+02,
        1.38357751867269e+02,
        -3.066479806614716e+01,
        2.506628277459239e+00,
    ];
    const B: [f64; 5] = [
        -5.447609879822406e+01,
        1.615858368580409e+02,
        -1.556989798598866e+02,
        6.680131188771972e+01,
        -1.328068155288572e+01,
    ];
    const C: [f64; 6] = [
        -7.784894002430293e-03,
        -3.223964580411365e-01,
        -2.400758277161838e+00,
        -2.549732539343734e+00,
        4.374664141464968e+00,
        2.938163982698783e+00,
    ];
    const D: [f64; 4] = [
        7.784695709041462e-03,
        3.224671290700398e-01,
        2.445134137142996e+00,
        3.754408661907416e+00,
    ];
    const P_LOW: f64 = 0.02425;
    let x = if p < P_LOW {
        let q = (-2.0 * p.ln()).sqrt();
        (((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0)
    } else if p <= 1.0 - P_LOW {
        let q = p - 0.5;
        let r = q * q;
        (((((A[0] * r + A[1]) * r + A[2]) * r + A[3]) * r + A[4]) * r + A[5]) * q
            / (((((B[0] * r + B[1]) * r + B[2]) * r + B[3]) * r + B[4]) * r + 1.0)
    } else {
        let q = (-2.0 * (1.0 - p).ln()).sqrt();
        -(((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0)
    };
    // Halley refinement.
    let e = norm_cdf(x) - p;
    let u = e * (2.0 * PI).sqrt() * (x * x / 2.0).exp();
    x - u / (1.0 + x * u / 2.0)
}

/// d1 and d2 of Black-Scholes-Merton.
pub(super) fn d1_d2(
    spot: f64,
    strike: f64,
    t: f64,
    rate: f64,
    div_yield: f64,
    sigma: f64,
) -> (f64, f64) {
    let vol_t = sigma * t.sqrt();
    let d1 = ((spot / strike).ln() + (rate - div_yield + 0.5 * sigma * sigma) * t) / vol_t;
    (d1, d1 - vol_t)
}

/// Theoretical per-share price. `t` is years to expiry, `rate` and
/// `div_yield` continuous annual fractions, `sigma` annual volatility.
/// At or past expiry returns intrinsic value.
pub fn price(
    kind: OptionKind,
    spot: f64,
    strike: f64,
    t: f64,
    rate: f64,
    div_yield: f64,
    sigma: f64,
) -> f64 {
    if t <= 0.0 || sigma <= 0.0 {
        return intrinsic(
            kind,
            spot * (-div_yield * t.max(0.0)).exp(),
            strike * (-rate * t.max(0.0)).exp(),
        );
    }
    let (d1, d2) = d1_d2(spot, strike, t, rate, div_yield, sigma);
    let disc_spot = spot * (-div_yield * t).exp();
    let disc_strike = strike * (-rate * t).exp();
    match kind {
        OptionKind::Call => disc_spot * norm_cdf(d1) - disc_strike * norm_cdf(d2),
        OptionKind::Put => disc_strike * norm_cdf(-d2) - disc_spot * norm_cdf(-d1),
    }
}

fn intrinsic(kind: OptionKind, spot: f64, strike: f64) -> f64 {
    match kind {
        OptionKind::Call => (spot - strike).max(0.0),
        OptionKind::Put => (strike - spot).max(0.0),
    }
}

/// Greeks at the same inputs as [`price`]. Returns None at or past expiry
/// or with non-positive volatility, where they are not defined.
pub fn greeks(
    kind: OptionKind,
    spot: f64,
    strike: f64,
    t: f64,
    rate: f64,
    div_yield: f64,
    sigma: f64,
) -> Option<Greeks> {
    if t <= 0.0 || sigma <= 0.0 || spot <= 0.0 || strike <= 0.0 {
        return None;
    }
    let (d1, d2) = d1_d2(spot, strike, t, rate, div_yield, sigma);
    let eq = (-div_yield * t).exp();
    let er = (-rate * t).exp();
    let sqrt_t = t.sqrt();
    let pdf1 = norm_pdf(d1);

    let gamma = eq * pdf1 / (spot * sigma * sqrt_t);
    let vega = spot * eq * pdf1 * sqrt_t;
    let (delta, theta, rho) = match kind {
        OptionKind::Call => (
            eq * norm_cdf(d1),
            -spot * eq * pdf1 * sigma / (2.0 * sqrt_t) - rate * strike * er * norm_cdf(d2)
                + div_yield * spot * eq * norm_cdf(d1),
            strike * t * er * norm_cdf(d2),
        ),
        OptionKind::Put => (
            -eq * norm_cdf(-d1),
            -spot * eq * pdf1 * sigma / (2.0 * sqrt_t) + rate * strike * er * norm_cdf(-d2)
                - div_yield * spot * eq * norm_cdf(-d1),
            -strike * t * er * norm_cdf(-d2),
        ),
    };
    Some(Greeks {
        delta,
        gamma,
        theta,
        vega,
        rho,
    })
}

/// Volatility that reproduces `market_price`. None when the price sits
/// outside the no-arbitrage band (below intrinsic, above the spot or strike
/// bound), which is common for stale closes on illiquid contracts, or when
/// the solve does not converge.
pub fn implied_vol(
    kind: OptionKind,
    market_price: f64,
    spot: f64,
    strike: f64,
    t: f64,
    rate: f64,
    div_yield: f64,
) -> Option<f64> {
    if t <= 0.0 || spot <= 0.0 || strike <= 0.0 || !market_price.is_finite() {
        return None;
    }
    let lower = price(kind, spot, strike, t, rate, div_yield, 1e-9);
    let upper = match kind {
        OptionKind::Call => spot * (-div_yield * t).exp(),
        OptionKind::Put => strike * (-rate * t).exp(),
    };
    if market_price <= lower || market_price >= upper {
        return None;
    }

    // Bisection bracket, then Newton from the midpoint with bisection
    // fallback: robust for the deep OTM wings where vega is tiny.
    let (mut lo, mut hi) = (1e-6_f64, 5.0_f64);
    let mut sigma = 0.3;
    for _ in 0..100 {
        let p = price(kind, spot, strike, t, rate, div_yield, sigma);
        let diff = p - market_price;
        if diff.abs() < 1e-12 * market_price.max(1.0) {
            return Some(sigma);
        }
        if diff > 0.0 {
            hi = sigma;
        } else {
            lo = sigma;
        }
        let vega = greeks(kind, spot, strike, t, rate, div_yield, sigma)
            .map(|g| g.vega)
            .unwrap_or(0.0);
        let newton = sigma - diff / vega;
        sigma = if vega > 1e-12 && newton > lo && newton < hi {
            newton
        } else {
            0.5 * (lo + hi)
        };
        if hi - lo < 1e-12 {
            return Some(sigma);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() <= tol
    }

    #[test]
    fn normal_cdf_matches_tables() {
        assert!(close(norm_cdf(0.0), 0.5, 1e-15));
        assert!(close(norm_cdf(1.0), 0.841344746068543, 1e-12));
        assert!(close(norm_cdf(-1.96), 0.024997895148220, 1e-12));
        assert!(close(norm_cdf(3.0), 0.998650101968370, 1e-12));
        assert!(close(norm_cdf(-6.0), 9.865876450377e-10, 1e-18));
    }

    #[test]
    fn inverse_normal_round_trips_and_matches_tables() {
        for x in [-6.0, -3.0, -1.96, -0.5, 0.0, 0.3, 1.0, 2.5, 5.0] {
            // The far tails lose digits to cancellation in 1 - p; 1e-9 is
            // far below anything a delta or strike solve can feel.
            let back = norm_inv(norm_cdf(x));
            assert!((back - x).abs() < 1e-9, "{x} -> {back}");
        }
        assert!((norm_inv(0.975) - 1.959963984540054).abs() < 1e-13);
        assert!((norm_inv(0.5)).abs() < 1e-15);
        assert_eq!(norm_inv(0.0), f64::NEG_INFINITY);
        assert_eq!(norm_inv(1.0), f64::INFINITY);
        assert!(norm_inv(1.5).is_nan());
    }

    #[test]
    fn hull_textbook_call_and_put() {
        // Hull, Options Futures and Other Derivatives, example 15.6:
        // S=42, K=40, r=10%, sigma=20%, T=0.5 → call 4.76, put 0.81.
        let c = price(OptionKind::Call, 42.0, 40.0, 0.5, 0.10, 0.0, 0.20);
        let p = price(OptionKind::Put, 42.0, 40.0, 0.5, 0.10, 0.0, 0.20);
        assert!(close(c, 4.7594, 1e-3), "call {c}");
        assert!(close(p, 0.8086, 1e-3), "put {p}");
    }

    #[test]
    fn at_the_money_reference_values() {
        // S=K=100, T=1, r=5%, q=0, sigma=20%: call 10.4506, put 5.5735.
        let c = price(OptionKind::Call, 100.0, 100.0, 1.0, 0.05, 0.0, 0.20);
        let p = price(OptionKind::Put, 100.0, 100.0, 1.0, 0.05, 0.0, 0.20);
        assert!(close(c, 10.4506, 1e-4), "call {c}");
        assert!(close(p, 5.5735, 1e-4), "put {p}");
    }

    #[test]
    fn put_call_parity_holds_with_dividends() {
        let (s, k, t, r, q, v) = (650.0, 640.0, 45.0 / 365.0, 0.045, 0.013, 0.18);
        let c = price(OptionKind::Call, s, k, t, r, q, v);
        let p = price(OptionKind::Put, s, k, t, r, q, v);
        let parity = s * (-q * t).exp() - k * (-r * t).exp();
        assert!(close(c - p, parity, 1e-9));
    }

    #[test]
    fn expiry_and_zero_vol_return_intrinsic() {
        assert_eq!(
            price(OptionKind::Call, 110.0, 100.0, 0.0, 0.05, 0.0, 0.2),
            10.0
        );
        assert_eq!(
            price(OptionKind::Put, 90.0, 100.0, 0.0, 0.05, 0.0, 0.2),
            10.0
        );
        assert_eq!(
            price(OptionKind::Call, 90.0, 100.0, 0.0, 0.05, 0.0, 0.2),
            0.0
        );
        assert!(greeks(OptionKind::Call, 100.0, 100.0, 0.0, 0.05, 0.0, 0.2).is_none());
    }

    #[test]
    fn greeks_match_finite_differences() {
        let (s, k, t, r, q, v) = (100.0, 105.0, 0.25, 0.03, 0.01, 0.25);
        let g = greeks(OptionKind::Put, s, k, t, r, q, v).unwrap();
        let h = 1e-4;
        let p = |s_, t_, r_, v_| price(OptionKind::Put, s_, k, t_, r_, q, v_);
        let delta = (p(s + h, t, r, v) - p(s - h, t, r, v)) / (2.0 * h);
        let gamma = (p(s + h, t, r, v) - 2.0 * p(s, t, r, v) + p(s - h, t, r, v)) / (h * h);
        let theta = -(p(s, t + h, r, v) - p(s, t - h, r, v)) / (2.0 * h);
        let vega = (p(s, t, r, v + h) - p(s, t, r, v - h)) / (2.0 * h);
        let rho = (p(s, t, r + h, v) - p(s, t, r - h, v)) / (2.0 * h);
        assert!(close(g.delta, delta, 1e-6), "delta {} vs {delta}", g.delta);
        assert!(close(g.gamma, gamma, 1e-4), "gamma {} vs {gamma}", g.gamma);
        assert!(close(g.theta, theta, 1e-4), "theta {} vs {theta}", g.theta);
        assert!(close(g.vega, vega, 1e-4), "vega {} vs {vega}", g.vega);
        assert!(close(g.rho, rho, 1e-4), "rho {} vs {rho}", g.rho);
        assert!(g.delta < 0.0 && g.delta > -1.0 && g.gamma > 0.0 && g.vega > 0.0);
    }

    #[test]
    fn implied_vol_round_trips_across_the_surface() {
        let (s, t, r, q) = (650.0, 30.0 / 365.0, 0.045, 0.013);
        for kind in [OptionKind::Call, OptionKind::Put] {
            for strike in [560.0, 620.0, 650.0, 680.0, 740.0] {
                for sigma in [0.08, 0.18, 0.45, 1.2] {
                    let p = price(kind, s, strike, t, r, q, sigma);
                    let iv = implied_vol(kind, p, s, strike, t, r, q)
                        .unwrap_or_else(|| panic!("{kind:?} K={strike} σ={sigma} p={p}"));
                    // The solve always reproduces the price. It recovers the
                    // volatility itself only where the price depends on it:
                    // a deep-ITM contract at low vol has no time value left
                    // to carry the information.
                    let back = price(kind, s, strike, t, r, q, iv);
                    assert!(
                        close(back, p, 1e-9 * p.max(1.0)),
                        "{kind:?} K={strike}: {back} vs {p}"
                    );
                    let vega = greeks(kind, s, strike, t, r, q, sigma).unwrap().vega;
                    if vega > 1e-2 {
                        assert!(
                            close(iv, sigma, 1e-6),
                            "{kind:?} K={strike}: {iv} vs {sigma}"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn implied_vol_rejects_arbitrage_prices() {
        // Below intrinsic for a call (S=110, K=100 → intrinsic ≈ 10).
        assert!(implied_vol(OptionKind::Call, 5.0, 110.0, 100.0, 0.1, 0.05, 0.0).is_none());
        // Above the spot bound.
        assert!(implied_vol(OptionKind::Call, 120.0, 110.0, 100.0, 0.1, 0.05, 0.0).is_none());
        // Zero price on an OTM put: stale close, not a volatility.
        assert!(implied_vol(OptionKind::Put, 0.0, 110.0, 90.0, 0.1, 0.05, 0.0).is_none());
    }

    #[test]
    fn contract_type_parses_vendor_and_occ_forms() {
        assert_eq!(OptionKind::parse("call"), Some(OptionKind::Call));
        assert_eq!(OptionKind::parse("P"), Some(OptionKind::Put));
        assert_eq!(OptionKind::parse("other"), None);
    }
}
