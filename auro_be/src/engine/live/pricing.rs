use crate::state::AppState;

/// Format a price for an OANDA order at the correct precision for the instrument.
///
/// Reads the display precision from the instrument metadata cache (loaded from
/// OANDA at startup). Falls back to a hardcoded table only if the cache has no
/// entry for the instrument (e.g., OANDA query failed at startup). The cache is
/// the source of truth; the fallback exists to keep the system functional during
/// cold-start or test-only paths.
pub async fn format_price(state: &AppState, instrument: &str, price: f64) -> String {
    let precision = lookup_precision(state, instrument).await;
    format_price_with_precision(precision, price)
}

/// Pure formatting function. No state required.
///
/// Useful for tests and any future call sites that already have the precision
/// in hand (e.g., when formatting a batch of prices for the same instrument).
pub fn format_price_with_precision(precision: usize, price: f64) -> String {
    format!("{:.*}", precision, price)
}

async fn lookup_precision(state: &AppState, instrument: &str) -> usize {
    let cached = {
        let meta = state.live.instrument_metadata.read().await;
        meta.get(instrument).map(|m| m.display_precision as usize)
    };

    match cached {
        Some(p) => p,
        None => {
            tracing::warn!(
                "[FORMAT_PRICE] No instrument_metadata for {} — using hardcoded fallback (may be stale)",
                instrument
            );
            price_precision_fallback(instrument)
        }
    }
}

/// Hardcoded precision table. FALLBACK ONLY — the OANDA-loaded cache is the
/// source of truth at runtime. Values here may drift from OANDA reality over
/// time; the cache normally overrides them.
pub fn price_precision_fallback(instrument: &str) -> usize {
    if instrument.ends_with("_JPY") {
        return 3;
    }
    if matches!(
        instrument,
        "SPX500_USD"
            | "NAS100_USD"
            | "US30_USD"
            | "US2000_USD"
            | "UK100_GBP"
            | "DE30_EUR"
            | "FR40_EUR"
            | "EU50_EUR"
            | "JP225_USD"
            | "AU200_AUD"
            | "HK33_HKD"
            | "CN50_USD"
            | "TWIX_USD"
            | "IN50_USD"
    ) {
        return 1;
    }
    if matches!(instrument, "XAU_USD" | "XPT_USD" | "XPD_USD") {
        return 2;
    }
    if instrument.starts_with("XAG_") {
        if instrument.ends_with("JPY") {
            return 1;
        }
        return 5;
    }
    if matches!(instrument, "BCO_USD" | "WTICO_USD") {
        return 3;
    }
    if instrument == "NATGAS_USD" {
        return 3;
    }
    if instrument == "XCU_USD" {
        return 4;
    }
    if matches!(instrument, "WHEAT_USD" | "CORN_USD") {
        return 3;
    }
    if instrument == "SOYBN_USD" {
        return 3;
    }
    if instrument.starts_with("USB")
        || instrument.starts_with("UK10")
        || instrument.starts_with("DE10")
    {
        return 3;
    }
    5
}

#[cfg(test)]
mod tests {
    use super::*;

    // -------------------------------------------------------------------------
    // Pure formatting (no state) — used for the bulk of the test surface.
    // -------------------------------------------------------------------------

    #[test]
    fn format_price_with_precision_rounds_to_decimals() {
        assert_eq!(format_price_with_precision(1, 10606.12345), "10606.1");
        assert_eq!(format_price_with_precision(5, 1.12345), "1.12345");
        assert_eq!(format_price_with_precision(3, 148.12345), "148.123");
        assert_eq!(format_price_with_precision(2, 3245.6789), "3245.68");
    }

    #[test]
    fn format_price_with_precision_rounds_not_truncates() {
        assert_eq!(format_price_with_precision(5, 1.123456), "1.12346");
        assert_eq!(format_price_with_precision(2, 3245.678), "3245.68");
    }

    // -------------------------------------------------------------------------
    // Fallback precision table — still tested because it's exercised when the
    // OANDA cache is empty (cold start, test paths).
    // -------------------------------------------------------------------------

    #[test]
    fn fallback_forex_majors_use_5_decimals() {
        assert_eq!(price_precision_fallback("EUR_USD"), 5);
        assert_eq!(price_precision_fallback("GBP_USD"), 5);
        assert_eq!(price_precision_fallback("AUD_USD"), 5);
        assert_eq!(price_precision_fallback("USD_CAD"), 5);
    }

    #[test]
    fn fallback_jpy_pairs_use_3_decimals() {
        assert_eq!(price_precision_fallback("USD_JPY"), 3);
        assert_eq!(price_precision_fallback("EUR_JPY"), 3);
        assert_eq!(price_precision_fallback("GBP_JPY"), 3);
        assert_eq!(price_precision_fallback("CHF_JPY"), 3);
    }

    #[test]
    fn fallback_indices_use_1_decimal() {
        assert_eq!(price_precision_fallback("UK100_GBP"), 1);
        assert_eq!(price_precision_fallback("SPX500_USD"), 1);
        assert_eq!(price_precision_fallback("NAS100_USD"), 1);
        assert_eq!(price_precision_fallback("DE30_EUR"), 1);
        assert_eq!(price_precision_fallback("EU50_EUR"), 1);
        assert_eq!(price_precision_fallback("AU200_AUD"), 1);
    }

    #[test]
    fn fallback_natural_gas_uses_3_decimals() {
        assert_eq!(price_precision_fallback("NATGAS_USD"), 3);
    }

    #[test]
    fn fallback_soybn_uses_3_decimals() {
        assert_eq!(price_precision_fallback("SOYBN_USD"), 3);
    }

    #[test]
    fn fallback_unknown_instrument_defaults_to_5() {
        assert_eq!(price_precision_fallback("SOME_UNKNOWN"), 5);
    }
}
