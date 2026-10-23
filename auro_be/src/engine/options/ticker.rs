//! OCC option symbols as Massive writes them: `O:SPY261219C00650000` =
//! underlying `SPY`, expiry 2026-12-19, call, strike 650.000 (eight digits,
//! three implied decimals). Flat files carry only this string, so the
//! loader needs to take it apart without a reference record.

use std::fmt;

use chrono::NaiveDate;

use super::OptionKind;

#[derive(Debug, Clone, PartialEq)]
pub struct OccTicker {
    pub underlying: String,
    pub expiration: NaiveDate,
    pub kind: OptionKind,
    pub strike: f64,
}

/// `YYMMDD` + `C`/`P` + eight strike digits.
const TAIL_LEN: usize = 6 + 1 + 8;

impl OccTicker {
    /// Accepts the `O:` prefix or the bare OCC string.
    pub fn parse(s: &str) -> Option<Self> {
        let body = s.strip_prefix("O:").unwrap_or(s);
        if body.len() <= TAIL_LEN || !body.is_ascii() {
            return None;
        }
        let (underlying, tail) = body.split_at(body.len() - TAIL_LEN);
        if underlying.is_empty()
            || !underlying
                .chars()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '.')
        {
            return None;
        }
        let (date, rest) = tail.split_at(6);
        let (kind, strike) = rest.split_at(1);
        if !date.bytes().all(|b| b.is_ascii_digit()) || !strike.bytes().all(|b| b.is_ascii_digit())
        {
            return None;
        }
        let expiration = NaiveDate::parse_from_str(&format!("20{date}"), "%Y%m%d").ok()?;
        let kind = OptionKind::parse(kind)?;
        let strike = strike.parse::<u64>().ok()? as f64 / 1000.0;
        Some(Self {
            underlying: underlying.to_string(),
            expiration,
            kind,
            strike,
        })
    }
}

impl fmt::Display for OccTicker {
    /// The Massive form, with the `O:` prefix.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let kind = match self.kind {
            OptionKind::Call => 'C',
            OptionKind::Put => 'P',
        };
        write!(
            f,
            "O:{}{}{}{:08}",
            self.underlying,
            self.expiration.format("%y%m%d"),
            kind,
            (self.strike * 1000.0).round() as u64
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_formats_the_vendor_form() {
        let t = OccTicker::parse("O:SPY261219C00650000").unwrap();
        assert_eq!(t.underlying, "SPY");
        assert_eq!(t.expiration, NaiveDate::from_ymd_opt(2026, 12, 19).unwrap());
        assert_eq!(t.kind, OptionKind::Call);
        assert_eq!(t.strike, 650.0);
        assert_eq!(t.to_string(), "O:SPY261219C00650000");
    }

    #[test]
    fn handles_fractional_strikes_share_classes_and_bare_form() {
        let t = OccTicker::parse("BRK.B261120P00452500").unwrap();
        assert_eq!(t.underlying, "BRK.B");
        assert_eq!(t.kind, OptionKind::Put);
        assert_eq!(t.strike, 452.5);
        assert_eq!(t.to_string(), "O:BRK.B261120P00452500");
        // Adjusted contracts carry a digit suffix on the root (AAPL1).
        assert_eq!(
            OccTicker::parse("O:AAPL1261120C00200000")
                .unwrap()
                .underlying,
            "AAPL1"
        );
    }

    #[test]
    fn rejects_malformed_symbols() {
        for bad in [
            "",
            "O:",
            "SPY",
            "O:SPY261219X00650000",
            "O:SPY2612A9C00650000",
            "O:spy261219C00650000",
            "O:SPY261232C00650000",
        ] {
            assert!(OccTicker::parse(bad).is_none(), "{bad}");
        }
    }
}
