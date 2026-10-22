import { onMounted, onUnmounted, ref } from "vue";

import { api, opusApi } from "../services/api";

interface SparklineCandle {
    timestamp: string;
    open: number;
    high: number;
    low: number;
    close: number;
    volume: number;
}

interface OpenTradeRiskRow {
    id: string;
    instrument: string;
    units: string;
    direction: "Long" | "Short";
    entry_price: number;
    current_price: number | null;
    pnl_pct: number | null;
    mfe_pct: number | null;
    mae_pct: number | null;
    stop_loss_state: string;
    stop_loss_price: number | null;
    take_profit_price: number | null;
    trailing_stop_loss_price: number | null;
    entry_time: string | null;
    strategy_id: string | null;
    granularity: string | null;
}

interface OpenTradesRiskResponse {
    trades: OpenTradeRiskRow[];
}

interface AccountResponse {
    balance: string;
    unrealized_pl: string;
    currency: string;
}

interface PricingResponse {
    prices: Array<{
        instrument: string;
        bids: Array<{ price: string }>;
        asks: Array<{ price: string }>;
    }>;
}

interface SparklineResponse {
    candles: SparklineCandle[];
}

export interface OpenPositionCardData extends OpenTradeRiskRow {
    notional: number;
    notional_pct_nav: number;
    sparkline: SparklineCandle[];
    // Account home currency (from the OANDA account snapshot, e.g. "CAD").
    home_currency: string;
    // Mid-market rate for converting USD quote currency to the home currency.
    // Null if rate fetch failed or the USD_{home} pair isn't available.
    usd_to_home_rate: number | null;
}

export function useOpenPositions() {
    const loading = ref(true);
    const accountNav = ref(0);
    const positions = ref<OpenPositionCardData[]>([]);

    let interval: ReturnType<typeof setInterval> | null = null;

    async function load() {
        try {
            const [account, tradesBody] = await Promise.all([
                api.get<AccountResponse>("/account"),
                api.get<OpenTradesRiskResponse>("/open-trades"),
            ]);

            const homeCurrency = account.currency || "CAD";

            // Mid-market USD/{home} rate. Used to convert USD-quoted position risk
            // to the account's home currency in the card display. Null on failure.
            let usdToHomeRate: number | null = homeCurrency === "USD" ? 1.0 : null;
            if (usdToHomeRate == null) {
                const pair = `USD_${homeCurrency}`;
                try {
                    const pricingBody = await api.get<PricingResponse>(
                        `/pricing?instruments=${pair}`,
                    );
                    const quote = pricingBody.prices?.find((p) => p.instrument === pair);
                    if (quote) {
                        const bid = Number(quote.bids?.[0]?.price);
                        const ask = Number(quote.asks?.[0]?.price);
                        if (Number.isFinite(bid) && Number.isFinite(ask) && bid > 0 && ask > 0) {
                            usdToHomeRate = (bid + ask) / 2;
                        }
                    }
                } catch {
                    usdToHomeRate = null;
                }
            }

            const nav = Number(account.balance || 0) + Number(account.unrealized_pl || 0);
            accountNav.value = nav > 0 ? nav : 0;

            const enriched = await Promise.all(
                (tradesBody.trades || []).map(async (t) => {
                    let sparkline: SparklineCandle[] = [];
                    try {
                        const sparklineBody = await opusApi.get<SparklineResponse>(
                            `/positions/${t.id}/sparkline?bars=60`,
                        );
                        sparkline = sparklineBody.candles || [];
                    } catch {
                        sparkline = [];
                    }

                    const unitsAbs = Math.abs(Number(t.units || "0"));
                    const currentPrice = t.current_price ?? t.entry_price;
                    const notional = unitsAbs * Math.abs(currentPrice || 0);
                    const notionalPct = accountNav.value > 0 ? (notional / accountNav.value) * 100 : 0;

                    return {
                        ...t,
                        notional,
                        notional_pct_nav: notionalPct,
                        sparkline,
                        home_currency: homeCurrency,
                        usd_to_home_rate: usdToHomeRate,
                    };
                }),
            );

            positions.value = enriched.sort((a, b) => b.notional - a.notional);
        } finally {
            loading.value = false;
        }
    }

    onMounted(() => {
        void load();
        interval = setInterval(() => {
            void load();
        }, 5000);
    });

    onUnmounted(() => {
        if (interval) clearInterval(interval);
    });

    return {
        loading,
        accountNav,
        positions,
        load,
    };
}
