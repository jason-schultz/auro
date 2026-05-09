/// Returns the number of decimal places OANDA expects for price strings on a given instrument.
pub fn price_precision(instrument: &str) -> usize {
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
        return 4;
    }
    if matches!(instrument, "BCO_USD" | "WTICO_USD") {
        return 3;
    }
    if instrument == "NATGAS_USD" {
        return 4;
    }
    if instrument == "XCU_USD" {
        return 4;
    }
    if instrument.starts_with("USB")
        || instrument.starts_with("UK10")
        || instrument.starts_with("DE10")
    {
        return 3;
    }
    5
}

/// Format a price for an OANDA order at the correct precision for the instrument.
pub fn format_price(instrument: &str, price: f64) -> String {
    format!("{:.*}", price_precision(instrument), price)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forex_majors_use_5_decimals() {
        assert_eq!(price_precision("EUR_USD"), 5);
        assert_eq!(price_precision("GBP_USD"), 5);
        assert_eq!(price_precision("AUD_USD"), 5);
        assert_eq!(price_precision("USD_CAD"), 5);
    }

    #[test]
    fn jpy_pairs_use_3_decimals() {
        assert_eq!(price_precision("USD_JPY"), 3);
        assert_eq!(price_precision("EUR_JPY"), 3);
        assert_eq!(price_precision("GBP_JPY"), 3);
        assert_eq!(price_precision("CHF_JPY"), 3);
    }

    #[test]
    fn indices_use_1_decimal() {
        assert_eq!(price_precision("UK100_GBP"), 1);
        assert_eq!(price_precision("SPX500_USD"), 1);
        assert_eq!(price_precision("NAS100_USD"), 1);
        assert_eq!(price_precision("DE30_EUR"), 1);
        assert_eq!(price_precision("EU50_EUR"), 1);
        assert_eq!(price_precision("AU200_AUD"), 1);
    }

    #[test]
    fn gold_platinum_palladium_use_2_decimals() {
        assert_eq!(price_precision("XAU_USD"), 2);
        assert_eq!(price_precision("XPT_USD"), 2);
        assert_eq!(price_precision("XPD_USD"), 2);
    }

    #[test]
    fn silver_uses_4_decimals() {
        assert_eq!(price_precision("XAG_USD"), 4);
    }

    #[test]
    fn oil_uses_3_decimals() {
        assert_eq!(price_precision("WTICO_USD"), 3);
        assert_eq!(price_precision("BCO_USD"), 3);
    }

    #[test]
    fn natural_gas_uses_4_decimals() {
        assert_eq!(price_precision("NATGAS_USD"), 4);
    }

    #[test]
    fn unknown_instrument_defaults_to_5() {
        assert_eq!(price_precision("SOME_UNKNOWN"), 5);
    }

    #[test]
    fn format_price_rounds_uk100_to_1_decimal() {
        let formatted = format_price("UK100_GBP", 10606.12345);
        assert_eq!(formatted, "10606.1");
    }

    #[test]
    fn format_price_keeps_forex_at_5_decimals() {
        let formatted = format_price("EUR_USD", 1.12345);
        assert_eq!(formatted, "1.12345");
    }

    #[test]
    fn format_price_jpy_pair_at_3_decimals() {
        let formatted = format_price("USD_JPY", 148.12345);
        assert_eq!(formatted, "148.123");
    }

    #[test]
    fn format_price_gold_at_2_decimals() {
        let formatted = format_price("XAU_USD", 3245.6789);
        assert_eq!(formatted, "3245.68");
    }

    #[test]
    fn format_price_rounds_not_truncates() {
        assert_eq!(format_price("EUR_USD", 1.123456), "1.12346");
        assert_eq!(format_price("XAU_USD", 3245.678), "3245.68");
    }
}
