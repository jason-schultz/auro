import { computed, ref } from "vue";
import { api, getApiErrorMessage } from "../services/api";
import { expectancy as calculateExpectancy } from "../lib/metrics";
import { getInstrumentCategory, MARKET_TABS } from "../lib/market";
import {
    STRATEGIES_COLUMNS,
    formatTableNumber,
    formatTablePercent,
} from "../lib/ui";
import type { LiveStrategy, LiveStrategiesResponse } from "../types/live";

export function useStrategies() {
    const strategies = ref<LiveStrategy[]>([]);
    const loading = ref(true);
    const activeTab = ref("all");
    const strategyFilter = ref("all");
    const statusFilter = ref("all");
    const sortKey = ref("instrument");
    const sortDir = ref<"asc" | "desc">("asc");
    const toggling = ref<string | null>(null);
    const deleting = ref<string | null>(null);
    const deleteConfirm = ref<string | null>(null);
    const errorMessage = ref("");

    const marketTabs = MARKET_TABS;

    const strategyFilters = [
        { id: "all", label: "All" },
        { id: "mean_reversion", label: "Mean Reversion" },
        { id: "trend_following", label: "Trend Following" },
    ];

    const statusFilters = [
        { id: "all", label: "All" },
        { id: "enabled", label: "Active" },
        { id: "disabled", label: "Inactive" },
    ];

    const columns = STRATEGIES_COLUMNS;

    const filteredStrategies = computed(() => {
        let filtered = strategies.value;

        if (activeTab.value !== "all") {
            filtered = filtered.filter((s) => getInstrumentCategory(s.instrument) === activeTab.value);
        }

        if (strategyFilter.value !== "all") {
            filtered = filtered.filter((s) => s.strategy_type === strategyFilter.value);
        }

        if (statusFilter.value === "enabled") {
            filtered = filtered.filter((s) => s.enabled);
        } else if (statusFilter.value === "disabled") {
            filtered = filtered.filter((s) => !s.enabled);
        }

        return filtered;
    });

    const sortedStrategies = computed(() => {
        const sorted = [...filteredStrategies.value];

        sorted.sort((a, b) => {
            let aVal: string | number;
            let bVal: string | number;

            switch (sortKey.value) {
                case "instrument":
                    aVal = a.instrument;
                    bVal = b.instrument;
                    break;
                case "strategy_type":
                    aVal = a.strategy_type;
                    bVal = b.strategy_type;
                    break;
                case "enabled":
                    aVal = a.enabled ? 1 : 0;
                    bVal = b.enabled ? 1 : 0;
                    break;
                case "total_return":
                    aVal = a.backtest_stats?.total_return ?? -999;
                    bVal = b.backtest_stats?.total_return ?? -999;
                    break;
                case "win_rate":
                    aVal = a.backtest_stats?.win_rate ?? -999;
                    bVal = b.backtest_stats?.win_rate ?? -999;
                    break;
                case "sharpe_ratio":
                    aVal = a.backtest_stats?.sharpe_ratio ?? -999;
                    bVal = b.backtest_stats?.sharpe_ratio ?? -999;
                    break;
                case "max_drawdown":
                    aVal = a.backtest_stats?.max_drawdown ?? -999;
                    bVal = b.backtest_stats?.max_drawdown ?? -999;
                    break;
                case "num_trades":
                    aVal = a.backtest_stats?.num_trades ?? -999;
                    bVal = b.backtest_stats?.num_trades ?? -999;
                    break;
                case "oos_sharpe":
                    aVal = a.oos_stats?.oos_sharpe ?? -999;
                    bVal = b.oos_stats?.oos_sharpe ?? -999;
                    break;
                case "live_num_trades":
                    aVal = a.live_stats?.num_trades ?? -1;
                    bVal = b.live_stats?.num_trades ?? -1;
                    break;
                case "live_win_rate":
                    aVal = a.live_stats?.win_rate ?? -1;
                    bVal = b.live_stats?.win_rate ?? -1;
                    break;
                default:
                    aVal = a.instrument;
                    bVal = b.instrument;
            }

            if (typeof aVal === "string" && typeof bVal === "string") {
                return sortDir.value === "asc" ? aVal.localeCompare(bVal) : bVal.localeCompare(aVal);
            }

            return sortDir.value === "asc"
                ? Number(aVal) - Number(bVal)
                : Number(bVal) - Number(aVal);
        });

        return sorted;
    });

    const enabledCount = computed(() => strategies.value.filter((s) => s.enabled).length);

    function tabCount(tabId: string): number {
        if (tabId === "all") return strategies.value.length;
        return strategies.value.filter((s) => getInstrumentCategory(s.instrument) === tabId).length;
    }

    function toggleSort(key: string) {
        if (sortKey.value === key) {
            sortDir.value = sortDir.value === "asc" ? "desc" : "asc";
        } else {
            sortKey.value = key;
            sortDir.value = key === "instrument" || key === "strategy_type" ? "asc" : "desc";
        }
    }

    function pct(value: number | null | undefined): string {
        return formatTablePercent(value);
    }

    function num(value: number | null | undefined, decimals = 2): string {
        return formatTableNumber(value, decimals);
    }

    function expectancy(winRate: number, avgWin: number, avgLoss: number): number {
        return calculateExpectancy(winRate, avgWin, avgLoss);
    }

    function winRateDeltaLabel(strategy: LiveStrategy): string {
        if (!strategy.live_stats || !strategy.backtest_stats) return "";
        const delta = strategy.live_stats.win_rate - strategy.backtest_stats.win_rate;
        const sign = delta >= 0 ? "+" : "";
        return `${sign}${(delta * 100).toFixed(1)}`;
    }

    function winRateDeltaClass(strategy: LiveStrategy): string {
        if (!strategy.live_stats || !strategy.backtest_stats) return "text-muted-foreground";
        const delta = strategy.live_stats.win_rate - strategy.backtest_stats.win_rate;
        if (Math.abs(delta) < 0.02) return "text-muted-foreground";
        return delta >= 0 ? "text-emerald-400" : "text-red-400";
    }

    function edgeStatus(strategy: LiveStrategy): { label: string; color: string } {
        const live = strategy.live_stats;
        const bt = strategy.backtest_stats;

        if (!live || !bt) {
            return { label: "—", color: "bg-muted/40 text-muted-foreground/60" };
        }

        if (live.num_trades < 5) {
            return { label: `${live.num_trades}/5`, color: "bg-muted text-muted-foreground" };
        }

        if (bt.avg_win == null || bt.avg_loss == null) {
            const delta = live.win_rate - bt.win_rate;
            if (live.win_rate <= 0.3) return { label: "Neg E", color: "bg-red-500/10 text-red-400" };
            if (Math.abs(delta) < 0.05) return { label: "Holding", color: "bg-emerald-500/10 text-emerald-400" };
            return delta >= 0
                ? { label: "Holding", color: "bg-emerald-500/10 text-emerald-400" }
                : { label: "Decay", color: "bg-amber-500/10 text-amber-400" };
        }

        const liveExp = expectancy(live.win_rate, live.avg_win, live.avg_loss);
        const btExp = expectancy(bt.win_rate, bt.avg_win, bt.avg_loss);

        if (liveExp <= 0 && btExp <= 0) {
            return { label: "Neg E", color: "bg-red-500/10 text-red-400" };
        }

        if (btExp <= 0) {
            return { label: "Live > BT", color: "bg-emerald-500/10 text-emerald-400" };
        }

        const ratio = liveExp / btExp;
        if (ratio >= 0.85) return { label: "Holding", color: "bg-emerald-500/10 text-emerald-400" };
        if (ratio >= 0.5) return { label: "Decay", color: "bg-amber-500/10 text-amber-400" };
        return { label: "Broken", color: "bg-red-500/10 text-red-400" };
    }

    function showError(msg: string) {
        errorMessage.value = msg;
        setTimeout(() => {
            errorMessage.value = "";
        }, 4000);
    }

    async function toggleStrategy(strategy: LiveStrategy) {
        toggling.value = strategy.id;
        try {
            const data = await api.post<{ id: string; enabled: boolean }>(`/live/strategies/${strategy.id}/toggle`, {});
            strategy.enabled = data.enabled;
        } catch (e) {
            showError(getApiErrorMessage(e, "Failed to toggle strategy"));
            console.error("Toggle failed:", e);
        } finally {
            toggling.value = null;
        }
    }

    async function deleteStrategy(strategy: LiveStrategy) {
        deleting.value = strategy.id;
        deleteConfirm.value = null;
        try {
            await api.delete(`/live/strategies/${strategy.id}`);
            strategies.value = strategies.value.filter((s) => s.id !== strategy.id);
        } catch (e) {
            showError(getApiErrorMessage(e, "Failed to delete strategy"));
            console.error("Delete failed:", e);
        } finally {
            deleting.value = null;
        }
    }

    async function loadStrategies() {
        loading.value = true;
        try {
            const data = await api.get<LiveStrategiesResponse>("/live/strategies");
            strategies.value = data.strategies;
        } catch (e) {
            showError(getApiErrorMessage(e, "Failed to load strategies"));
            console.error("Failed to load strategies:", e);
        } finally {
            loading.value = false;
        }
    }

    return {
        strategies,
        loading,
        activeTab,
        strategyFilter,
        statusFilter,
        sortKey,
        sortDir,
        toggling,
        deleting,
        deleteConfirm,
        errorMessage,
        marketTabs,
        strategyFilters,
        statusFilters,
        columns,
        filteredStrategies,
        sortedStrategies,
        enabledCount,
        tabCount,
        toggleSort,
        pct,
        num,
        winRateDeltaLabel,
        winRateDeltaClass,
        edgeStatus,
        showError,
        toggleStrategy,
        deleteStrategy,
        loadStrategies,
    };
}
