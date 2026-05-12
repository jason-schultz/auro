const INDEX_INSTRUMENTS = new Set([
    "SPX500_USD",
    "NAS100_USD",
    "US30_USD",
    "UK100_GBP",
    "DE30_EUR",
    "EU50_EUR",
    "JP225_USD",
    "AU200_AUD",
]);

const TWO_DECIMAL_INSTRUMENTS = new Set(["XAU_USD", "XPT_USD", "XPD_USD"]);
const THREE_DECIMAL_INSTRUMENTS = new Set(["BCO_USD", "WTICO_USD"]);
const FOUR_DECIMAL_INSTRUMENTS = new Set(["NATGAS_USD", "XCU_USD"]);

export function getInstrumentDecimals(instrument: string): number {
    if (instrument.endsWith("_JPY")) return 3;
    if (INDEX_INSTRUMENTS.has(instrument)) return 1;
    if (TWO_DECIMAL_INSTRUMENTS.has(instrument)) return 2;
    if (instrument.startsWith("XAG_")) return 4;
    if (THREE_DECIMAL_INSTRUMENTS.has(instrument)) return 3;
    if (FOUR_DECIMAL_INSTRUMENTS.has(instrument)) return 4;
    return 5;
}
