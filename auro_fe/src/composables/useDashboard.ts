import { onMounted, onUnmounted, ref } from "vue";
import { api } from "../services/api";
import { formatStrategyConfigLabel } from "../lib/strategy";
import { formatDurationCompact, timeAgoCompact } from "../lib/time";
import type {
    AlgoEntry,
    LiveTradeRecord,
    LiveTradesResponse,
} from "../types/live";

function asNumber(value: string | number | null | undefined): number | null {
    if (value == null) return null;
    const parsed = typeof value === "number" ? value : parseFloat(value);
    return Number.isFinite(parsed) ? parsed : null;
}

export function useDashboard() {
    const algoActivity = ref<AlgoEntry[]>([]);
    const algoLoading = ref(true);

    let refreshInterval: ReturnType<typeof setInterval> | null = null;

    function formatPrice(price: number | null, instrument: string): string {
        if (price == null || !Number.isFinite(price)) return "-";
        return price.toFixed(instrument.includes("JPY") ? 3 : 5);
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

    function reasonShort(reason?: string | null): string {
        if (!reason) return "";
        const compact = reason.replace(/[_-]+/g, " ").trim();
        return compact.length > 34 ? `${compact.slice(0, 34)}...` : compact;
    }

    function exitReasonColor(reason?: string | null): string {
        if (!reason) return "text-muted-foreground";
        const r = reason.toLowerCase();
        if (r.includes("take profit") || r.includes("tp")) return "text-emerald-400";
        if (r.includes("stop") || r.includes("sl")) return "text-red-400";
        if (r.includes("trailing")) return "text-blue-400";
        return "text-muted-foreground";
    }

    function mapTradeToAlgoEntry(trade: LiveTradeRecord): AlgoEntry {
        const direction = (trade.direction || "").toLowerCase();
        const status = (trade.status || "").toLowerCase();
        const isClosed = status.includes("closed");
        const side = direction === "short" ? "Short" : "Long";

        const entryTime = trade.entry_time;
        const exitTime = trade.exit_time;

        return {
            id: trade.id,
            instrument: trade.instrument,
            direction: trade.direction,
            units: trade.units,
            action: `${isClosed ? "Closed" : "Opened"} ${side}`,
            entryReason: trade.entry_reason ?? "",
            exitReason: trade.exit_reason ?? "",
            entryPrice: asNumber(trade.entry_price),
            exitPrice: asNumber(trade.exit_price),
            duration: exitTime ? formatDurationCompact(entryTime, exitTime) : null,
            status: trade.status,
            time: timeAgoCompact(exitTime || entryTime),
            pnl: trade.pnl_percent,
            strategyLabel: formatStrategyConfigLabel(
                trade.strategy_type,
                trade.strategy_parameters,
                trade.strategy_granularity,
            ),
        };
    }

    async function loadAlgoActivity() {
        try {
            const data = await api.get<LiveTradesResponse>("/live-trades");
            algoActivity.value = (data.trades || []).slice(0, 12).map(mapTradeToAlgoEntry);
        } catch (e) {
            console.error("Failed to load algo activity:", e);
            algoActivity.value = [];
        } finally {
            algoLoading.value = false;
        }
    }

    async function refreshAll() {
        await loadAlgoActivity();
    }

    onMounted(() => {
        refreshAll();
        refreshInterval = setInterval(refreshAll, 15000);
    });

    onUnmounted(() => {
        if (refreshInterval) clearInterval(refreshInterval);
    });

    return {
        algoActivity,
        algoLoading,
        actionColor,
        formatPrice,
        reasonShort,
        exitReasonColor,
    };
}
