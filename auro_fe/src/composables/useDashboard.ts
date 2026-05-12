import { onMounted, onUnmounted, ref, watch } from "vue";
import { useMarketStore } from "../stores/market";
import { api } from "../services/api";
import { formatCadCurrency } from "../lib/format";
import { getInstrumentDecimals } from "../lib/instruments";
import { formatStrategyConfigLabel } from "../lib/strategy";
import { formatDurationCompact, timeAgoCompact } from "../lib/time";
import type {
    AccountData,
    AlgoEntry,
    LiveTradeRecord,
    LiveTradesResponse,
    OpenTrade,
    OpenTradesResponse,
    Position,
    StopDisplay,
    TargetDisplay,
} from "../types/live";

export function useDashboard() {
    const marketStore = useMarketStore();

    const account = ref<AccountData | null>(null);
    const positions = ref<Position[]>([]);
    const positionsLoading = ref(true);
    const algoActivity = ref<AlgoEntry[]>([]);
    const algoLoading = ref(true);
    const lastKnownPrices = ref<Record<string, number>>({});

    let refreshInterval: ReturnType<typeof setInterval> | null = null;

    watch(
        () => marketStore.prices,
        (prices) => {
            for (const [instrument, price] of Object.entries(prices)) {
                if (price?.ask) {
                    lastKnownPrices.value[instrument] = parseFloat(price.ask);
                }
            }
        },
        { deep: true },
    );

    function getLastKnownPrice(instrument: string): number | null {
        return lastKnownPrices.value[instrument] ?? null;
    }

    function formatCurrency(value: string): string {
        return formatCadCurrency(value);
    }

    function actionColor(action: string): string {
        if (action.startsWith("Opened") && action.includes("Long")) {
            return "bg-emerald-500/10 text-emerald-400";
        }
        if (action.startsWith("Opened") && action.includes("Short")) {
            return "bg-red-500/10 text-red-400";
        }
        if (action.startsWith("Closed")) {
            return "bg-muted text-muted-foreground";
        }
        return "bg-secondary text-muted-foreground";
    }

    function stateColor(state: string): string {
        switch (state) {
            case "Trailing":
                return "bg-emerald-500/10 text-emerald-400";
            case "Breakeven":
                return "bg-blue-500/10 text-blue-400";
            case "Initial":
                return "bg-muted text-muted-foreground";
            default:
                return "bg-secondary text-muted-foreground";
        }
    }

    function determineStopLossState(trade: OpenTrade): string {
        if (trade.trailingStopLossOrder) return "Trailing";
        if (trade.stopLossOrder) {
            const slRaw = trade.stopLossOrder.price;
            if (!slRaw) return "Initial";
            const slPrice = parseFloat(slRaw);
            const entry = parseFloat(trade.price);
            if (entry > 0 && Math.abs(slPrice - entry) / entry < 0.0001) {
                return "Breakeven";
            }
            return "Initial";
        }
        return "None";
    }

    function buildStopDisplay(
        trade: OpenTrade,
        currentPrice: number | null,
        isLong: boolean,
    ): StopDisplay | null {
        if (!currentPrice) return null;

        if (trade.trailingStopLossOrder) {
            const distanceRaw = trade.trailingStopLossOrder.distance;
            if (!distanceRaw) return null;
            const distance = parseFloat(distanceRaw);
            const stopPrice = isLong
                ? currentPrice - distance
                : currentPrice + distance;
            const distancePct = (distance / currentPrice) * 100;
            return {
                priceLabel: `$${stopPrice.toFixed(getDecimals(trade.instrument))}`,
                distanceLabel: `${distancePct.toFixed(2)}% trail`,
                distanceClass: "text-emerald-400",
            };
        }

        if (trade.stopLossOrder) {
            const slRaw = trade.stopLossOrder.price;
            if (!slRaw) return null;
            const slPrice = parseFloat(slRaw);
            const distancePct = ((slPrice - currentPrice) / currentPrice) * 100;
            const sign = distancePct >= 0 ? "+" : "";
            return {
                priceLabel: `$${slPrice.toFixed(getDecimals(trade.instrument))}`,
                distanceLabel: `${sign}${distancePct.toFixed(2)}%`,
                distanceClass: "text-muted-foreground",
            };
        }

        return null;
    }

    function buildTargetDisplay(
        trade: OpenTrade,
        currentPrice: number | null,
    ): TargetDisplay | null {
        if (!trade.takeProfitOrder || !currentPrice) return null;
        const tpRaw = trade.takeProfitOrder.price;
        if (!tpRaw) return null;
        const tpPrice = parseFloat(tpRaw);
        const distancePct = ((tpPrice - currentPrice) / currentPrice) * 100;
        const sign = distancePct >= 0 ? "+" : "";
        return {
            price: tpPrice.toFixed(getDecimals(trade.instrument)),
            distanceLabel: `${sign}${distancePct.toFixed(2)}%`,
            distanceClass: "text-muted-foreground",
        };
    }

    function getDecimals(instrument: string): number {
        return getInstrumentDecimals(instrument);
    }

    function formatPrice(price: number | null, instrument: string): string {
        if (price == null || price <= 0) return "—";
        return price.toFixed(getDecimals(instrument));
    }

    function reasonShort(reason: string): string {
        if (!reason) return "";
        const colonIdx = reason.indexOf(":");
        return colonIdx === -1 ? reason : reason.substring(0, colonIdx).trim();
    }

    function exitReasonColor(reason: string): string {
        switch (reasonShort(reason)) {
            case "TakeProfit":
            case "TrailingStop":
                return "text-emerald-400";
            case "StopLoss":
                return "text-red-400";
            case "TrendReversal":
                return "text-amber-400";
            case "ClosedByBroker":
                return "text-muted-foreground";
            default:
                return "text-foreground";
        }
    }

    function formatDuration(
        startStr: string | null | undefined,
        endStr: string | null | undefined,
    ): string | null {
        return formatDurationCompact(startStr, endStr);
    }

    function timeAgo(dateStr: string): string {
        return timeAgoCompact(dateStr);
    }

    async function loadAccount() {
        try {
            account.value = await api.get<AccountData>("/account");
        } catch (e) {
            console.error("Failed to load account:", e);
        }
    }

    async function loadPositions() {
        try {
            const data = await api.get<OpenTradesResponse>("/open-trades");
            positions.value = (data.trades || []).map((t: OpenTrade) => {
                const livePrice = marketStore.prices[t.instrument];
                const currentPrice = livePrice
                    ? parseFloat(livePrice.ask)
                    : getLastKnownPrice(t.instrument);

                const entryPrice = parseFloat(t.price || "0");
                const units = parseFloat(t.currentUnits || t.initialUnits || "0");
                const pl = parseFloat(t.unrealizedPL || "0");
                const isLong = units > 0;

                return {
                    id: t.id,
                    instrument: t.instrument,
                    side: isLong ? "Long" : "Short",
                    units: Math.abs(units).toString(),
                    entry: entryPrice ? entryPrice.toString() : "—",
                    current: currentPrice ? currentPrice.toFixed(getDecimals(t.instrument)) : "-",
                    pl,
                    stopLossState: determineStopLossState(t),
                    stopDisplay: buildStopDisplay(t, currentPrice, isLong),
                    targetDisplay: buildTargetDisplay(t, currentPrice),
                };
            });
        } catch (e) {
            console.error("Failed to load positions:", e);
        } finally {
            positionsLoading.value = false;
        }
    }

    async function loadAlgoActivity() {
        try {
            const data = await api.get<LiveTradesResponse>("/live/trades?limit=20");
            algoActivity.value = (data.trades || []).map((t: LiveTradeRecord) => {
                const isClosed = t.status === "closed";
                const action = isClosed
                    ? `Closed ${t.direction}`
                    : `Opened ${t.direction}`;

                const entryPrice =
                    t.entry_price != null ? Number(t.entry_price) : null;
                const rawExitPrice =
                    t.exit_price != null ? Number(t.exit_price) : null;
                const exitPrice =
                    rawExitPrice != null && rawExitPrice > 0 ? rawExitPrice : null;

                return {
                    id: t.id,
                    instrument: t.instrument,
                    direction: t.direction,
                    units: t.units,
                    action,
                    entryReason: t.entry_reason || "",
                    exitReason: t.exit_reason || "",
                    entryPrice,
                    exitPrice,
                    duration: isClosed
                        ? formatDuration(t.entry_time, t.exit_time)
                        : null,
                    status: t.status,
                    time: timeAgo(
                        isClosed && t.exit_time ? t.exit_time : t.entry_time,
                    ),
                    pnl: t.pnl_percent != null ? t.pnl_percent : null,
                    strategyLabel: formatStrategyConfigLabel(
                        t.strategy_type,
                        t.strategy_parameters,
                        t.strategy_granularity,
                    ),
                };
            });
        } catch (e) {
            console.error("Failed to load algo activity:", e);
        } finally {
            algoLoading.value = false;
        }
    }

    async function refreshAll() {
        await Promise.all([loadAccount(), loadPositions(), loadAlgoActivity()]);
    }

    onMounted(() => {
        refreshAll();
        refreshInterval = setInterval(refreshAll, 15000);
    });

    onUnmounted(() => {
        if (refreshInterval) clearInterval(refreshInterval);
    });

    return {
        account,
        positions,
        positionsLoading,
        algoActivity,
        algoLoading,
        formatCurrency,
        actionColor,
        stateColor,
        formatPrice,
        reasonShort,
        exitReasonColor,
    };
}
