export type MarketCategory =
    | "forex"
    | "metals"
    | "commodities"
    | "indices"
    | "bonds";

export const MARKET_TABS: Array<{ id: MarketCategory | "all"; label: string }> = [
    { id: "all", label: "All" },
    { id: "forex", label: "Forex" },
    { id: "metals", label: "Metals" },
    { id: "commodities", label: "Commodities" },
    { id: "indices", label: "Indices" },
    { id: "bonds", label: "Bonds" },
];

export const MARKET_TABS_WITH_TSX: Array<{ id: MarketCategory | "tsx"; label: string }> = [
    { id: "forex", label: "Forex" },
    { id: "metals", label: "Metals" },
    { id: "commodities", label: "Commodities" },
    { id: "indices", label: "Indices" },
    { id: "bonds", label: "Bonds" },
    { id: "tsx", label: "TSX" },
];

const CATEGORY_BY_INSTRUMENT: Record<string, MarketCategory> = {
    EUR_USD: "forex",
    GBP_USD: "forex",
    USD_JPY: "forex",
    AUD_USD: "forex",
    USD_CAD: "forex",
    NZD_USD: "forex",
    USD_CHF: "forex",
    EUR_GBP: "forex",
    EUR_JPY: "forex",
    GBP_JPY: "forex",
    AUD_JPY: "forex",
    EUR_AUD: "forex",
    EUR_CAD: "forex",
    EUR_CHF: "forex",
    EUR_NZD: "forex",
    GBP_AUD: "forex",
    GBP_CAD: "forex",
    GBP_CHF: "forex",
    GBP_NZD: "forex",
    AUD_CAD: "forex",
    AUD_CHF: "forex",
    AUD_NZD: "forex",
    NZD_CAD: "forex",
    NZD_CHF: "forex",
    NZD_JPY: "forex",
    CAD_JPY: "forex",
    CAD_CHF: "forex",
    CHF_JPY: "forex",
    USD_SGD: "forex",
    EUR_SGD: "forex",
    SGD_JPY: "forex",
    USD_HKD: "forex",
    USD_NOK: "forex",
    USD_SEK: "forex",
    USD_DKK: "forex",
    EUR_NOK: "forex",
    EUR_SEK: "forex",
    EUR_DKK: "forex",
    USD_CNH: "forex",
    EUR_HUF: "forex",
    USD_HUF: "forex",
    EUR_PLN: "forex",
    USD_PLN: "forex",
    EUR_CZK: "forex",
    USD_CZK: "forex",
    USD_MXN: "forex",
    USD_ZAR: "forex",
    EUR_ZAR: "forex",
    USD_TRY: "forex",
    EUR_TRY: "forex",
    USD_THB: "forex",
    USD_INR: "forex",
    XAU_USD: "metals",
    XAG_USD: "metals",
    XAU_EUR: "metals",
    XAG_EUR: "metals",
    XAU_GBP: "metals",
    XAG_GBP: "metals",
    XAU_AUD: "metals",
    XAG_AUD: "metals",
    XAU_CAD: "metals",
    XAG_CAD: "metals",
    XAU_CHF: "metals",
    XAG_CHF: "metals",
    XAU_JPY: "metals",
    XAG_JPY: "metals",
    XAU_NZD: "metals",
    XAG_NZD: "metals",
    XAU_SGD: "metals",
    XAG_SGD: "metals",
    XAU_HKD: "metals",
    XPT_USD: "metals",
    XPD_USD: "metals",
    BCO_USD: "commodities",
    WTICO_USD: "commodities",
    NATGAS_USD: "commodities",
    SOYBN_USD: "commodities",
    CORN_USD: "commodities",
    SUGAR_USD: "commodities",
    WHEAT_USD: "commodities",
    SPX500_USD: "indices",
    NAS100_USD: "indices",
    US30_USD: "indices",
    US2000_USD: "indices",
    UK100_GBP: "indices",
    DE30_EUR: "indices",
    FR40_EUR: "indices",
    EU50_EUR: "indices",
    JP225_USD: "indices",
    AU200_AUD: "indices",
    HK33_HKD: "indices",
    SG30_SGD: "indices",
    CN50_USD: "indices",
    TWIX_USD: "indices",
    IN50_USD: "indices",
    USB02Y_USD: "bonds",
    USB05Y_USD: "bonds",
    USB10Y_USD: "bonds",
    USB30Y_USD: "bonds",
    UK10YB_GBP: "bonds",
    DE10YB_EUR: "bonds",
};

const INDEX_INSTRUMENTS = new Set([
    "SPX500_USD",
    "NAS100_USD",
    "US30_USD",
    "JP225_USD",
    "DE30_EUR",
    "UK100_GBP",
    "EU50_EUR",
    "AU200_AUD",
]);

const SOFT_COMMODITIES = new Set([
    "NATGAS_USD",
    "CORN_USD",
    "SOYBN_USD",
    "SUGAR_USD",
    "WHEAT_USD",
]);

export function getInstrumentCategory(instrument: string): MarketCategory {
    return CATEGORY_BY_INSTRUMENT[instrument] ?? "forex";
}

export function defaultDeployUnits(instrument: string): string {
    if (instrument.startsWith("XAU_")) return "1";
    if (instrument.startsWith("XAG_")) return "10";
    if (instrument.startsWith("XPT_") || instrument.startsWith("XPD_")) return "1";
    if (instrument.startsWith("XCU_")) return "100";
    if (instrument === "BCO_USD" || instrument === "WTICO_USD") return "10";
    if (SOFT_COMMODITIES.has(instrument)) return "100";
    if (INDEX_INSTRUMENTS.has(instrument)) return "1";
    if (instrument.startsWith("USB") || instrument.startsWith("UK10") || instrument.startsWith("DE10")) {
        return "1";
    }
    return "1000";
}
