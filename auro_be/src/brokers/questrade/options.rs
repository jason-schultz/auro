//! Questrade's option chain turned into the contracts we store. The chain
//! endpoint lists every expiry and strike on an underlying with the call
//! and put symbol IDs; this module keeps the part inside the expiry window
//! and strike band and names each contract in the OCC form that
//! `option_contracts` keys on, so Questrade quotes and Massive bars for the
//! same contract share a row.

use chrono::NaiveDate;

use super::models::ChainExpiry;
use crate::engine::options::{ContractSpec, OccTicker, OptionKind};
use crate::error::{AppError, AppResult};

/// A contract inside the window, with the Questrade ID its quote comes under.
#[derive(Debug, Clone, PartialEq)]
pub struct SelectedContract {
    pub spec: ContractSpec,
    pub option_id: i64,
}

/// Contracts on `underlying` expiring within `expiries` and striking within
/// `strikes` (both inclusive), nearest expiry first, then strike, then call
/// before put. A strike missing one side's ID yields only the other side.
pub fn select_contracts(
    chain: &[ChainExpiry],
    underlying: &str,
    expiries: (NaiveDate, NaiveDate),
    strikes: (f64, f64),
) -> AppResult<Vec<SelectedContract>> {
    let mut out = Vec::new();
    for expiry in chain {
        let expiration = expiry_date(&expiry.expiry_date)?;
        if expiration < expiries.0 || expiration > expiries.1 {
            continue;
        }
        let exercise_style = expiry
            .option_exercise_type
            .as_deref()
            .map(str::to_lowercase);
        for root in &expiry.chain_per_root {
            for strike in &root.chain_per_strike_price {
                if strike.strike_price < strikes.0 || strike.strike_price > strikes.1 {
                    continue;
                }
                let sides = [
                    (OptionKind::Call, strike.call_symbol_id),
                    (OptionKind::Put, strike.put_symbol_id),
                ];
                for (kind, option_id) in sides {
                    let Some(option_id) = option_id else {
                        continue;
                    };
                    let ticker = OccTicker {
                        underlying: root.option_root.clone(),
                        expiration,
                        kind,
                        strike: strike.strike_price,
                    };
                    out.push(SelectedContract {
                        spec: ContractSpec {
                            ticker: ticker.to_string(),
                            underlying: underlying.to_string(),
                            kind,
                            expiration,
                            strike: strike.strike_price,
                            shares_per_contract: root.multiplier,
                            exercise_style: exercise_style.clone(),
                            primary_exchange: expiry.listing_exchange.clone(),
                        },
                        option_id,
                    });
                }
            }
        }
    }
    out.sort_by(|a, b| {
        a.spec
            .expiration
            .cmp(&b.spec.expiration)
            .then(a.spec.strike.total_cmp(&b.spec.strike))
            .then_with(|| a.spec.kind.as_str().cmp(b.spec.kind.as_str()))
    });
    Ok(out)
}

/// `2026-11-20T00:00:00.000000-05:00` → 2026-11-20. The calendar date is the
/// expiry; the offset is Questrade's, not a conversion to apply.
fn expiry_date(s: &str) -> AppResult<NaiveDate> {
    s.get(..10)
        .and_then(|d| NaiveDate::parse_from_str(d, "%Y-%m-%d").ok())
        .ok_or_else(|| AppError::Internal(format!("Bad Questrade expiry date {s:?}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::brokers::questrade::models::OptionChainResponse;

    fn chain() -> Vec<ChainExpiry> {
        let json = r#"{"optionChain":[
          {"expiryDate":"2026-11-20T00:00:00.000000-05:00","description":"SPDR S&P 500",
           "listingExchange":"OPRA","optionExerciseType":"American",
           "chainPerRoot":[{"optionRoot":"SPY","multiplier":100,"chainPerStrikePrice":[
             {"strikePrice":600,"callSymbolId":1,"putSymbolId":2},
             {"strikePrice":650,"callSymbolId":3,"putSymbolId":4},
             {"strikePrice":700,"callSymbolId":5,"putSymbolId":null},
             {"strikePrice":800,"callSymbolId":7,"putSymbolId":8}]}]},
          {"expiryDate":"2027-03-19T00:00:00.000000-05:00","listingExchange":"OPRA",
           "optionExerciseType":"American",
           "chainPerRoot":[{"optionRoot":"SPY","chainPerStrikePrice":[
             {"strikePrice":650,"callSymbolId":9,"putSymbolId":10}]}]}
        ]}"#;
        serde_json::from_str::<OptionChainResponse>(json)
            .unwrap()
            .option_chain
    }

    fn date(y: i32, m: u32, d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, d).unwrap()
    }

    #[test]
    fn keeps_the_window_and_names_contracts_in_occ_form() {
        let selected = select_contracts(
            &chain(),
            "SPY",
            (date(2026, 10, 22), date(2026, 12, 6)),
            (585.0, 715.0),
        )
        .unwrap();
        let tickers: Vec<&str> = selected.iter().map(|c| c.spec.ticker.as_str()).collect();
        assert_eq!(
            tickers,
            [
                "O:SPY261120C00600000",
                "O:SPY261120P00600000",
                "O:SPY261120C00650000",
                "O:SPY261120P00650000",
                "O:SPY261120C00700000",
            ]
        );
        let ids: Vec<i64> = selected.iter().map(|c| c.option_id).collect();
        assert_eq!(ids, [1, 2, 3, 4, 5]);
        let first = &selected[0].spec;
        assert_eq!(first.underlying, "SPY");
        assert_eq!(first.kind, OptionKind::Call);
        assert_eq!(first.expiration, date(2026, 11, 20));
        assert_eq!(first.shares_per_contract, 100);
        assert_eq!(first.exercise_style.as_deref(), Some("american"));
        assert_eq!(first.primary_exchange.as_deref(), Some("OPRA"));
    }

    #[test]
    fn multiplier_defaults_and_far_expiries_are_excluded() {
        let selected = select_contracts(
            &chain(),
            "SPY",
            (date(2026, 10, 22), date(2027, 12, 31)),
            (640.0, 660.0),
        )
        .unwrap();
        assert_eq!(selected.len(), 4);
        assert_eq!(selected[2].spec.expiration, date(2027, 3, 19));
        assert_eq!(selected[2].spec.shares_per_contract, 100);
    }

    #[test]
    fn the_documented_field_names_are_also_accepted() {
        let json = r#"{"options":[{"expiryDate":"2026-11-20T00:00:00.000000-05:00",
          "chainPerRoot":[{"root":"SPY","chainPerStrikePrice":[
            {"strikePrice":650,"callSymbolId":3,"putSymbolId":4}]}]}]}"#;
        let chain = serde_json::from_str::<OptionChainResponse>(json)
            .unwrap()
            .option_chain;
        assert_eq!(chain[0].chain_per_root[0].option_root, "SPY");
    }

    #[test]
    fn a_bad_expiry_date_is_an_error_not_a_skip() {
        let mut chain = chain();
        chain[0].expiry_date = "soon".into();
        assert!(select_contracts(
            &chain,
            "SPY",
            (date(2026, 10, 22), date(2026, 12, 6)),
            (0.0, f64::MAX)
        )
        .is_err());
    }
}
