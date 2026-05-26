import { onMounted, onUnmounted, ref } from "vue";

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
    // Mid-market rate for converting USD quote currency to CAD (account currency).
    // Null if rate fetch failed or USD_CAD isn't available.
    usd_to_cad_rate: number | null;
}

export function useOpenPositions() {
    const loading = ref(true);
    const accountNav = ref(0);
    const positions = ref<OpenPositionCardData[]>([]);

    let interval: ReturnType<typeof setInterval> | null = null;

    async function load() {
        try {
            const [accountRes, tradesRes, usdCadRes] = await Promise.all([
                fetch("/api/account"),
                fetch("/api/open-trades"),
                fetch("/api/pricing?instruments=USD_CAD"),
            ]);

            const account = (await accountRes.json()) as AccountResponse;
            const tradesBody = (await tradesRes.json()) as OpenTradesRiskResponse;

            // Mid-market USD/CAD rate. Used to convert USD-quoted position risk
            // to account currency (CAD) in the card display. Null on failure.
            let usdToCadRate: number | null = null;
            try {
                if (usdCadRes.ok) {
                    const pricingBody = (await usdCadRes.json()) as PricingResponse;
                    const usdCad = pricingBody.prices?.find((p) => p.instrument === "USD_CAD");
                    if (usdCad) {
                        const bid = Number(usdCad.bids?.[0]?.price);
                        const ask = Number(usdCad.asks?.[0]?.price);
                        if (Number.isFinite(bid) && Number.isFinite(ask) && bid > 0 && ask > 0) {
                            usdToCadRate = (bid + ask) / 2;
                        }
                    }
                }
            } catch {
                usdToCadRate = null;
            }

            const nav = Number(account.balance || 0) + Number(account.unrealized_pl || 0);
            accountNav.value = nav > 0 ? nav : 0;

            const enriched = await Promise.all(
                (tradesBody.trades || []).map(async (t) => {
                    let sparkline: SparklineCandle[] = [];
                    try {
                        const sparklineRes = await fetch(`/opus/positions/${t.id}/sparkline?bars=60`);
                        if (sparklineRes.ok) {
                            const sparklineBody = (await sparklineRes.json()) as SparklineResponse;
                            sparkline = sparklineBody.candles || [];
                        }
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
                        usd_to_cad_rate: usdToCadRate,
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
