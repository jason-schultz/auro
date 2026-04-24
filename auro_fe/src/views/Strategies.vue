<template>
    <main class="p-6 h-[calc(100vh-57px)] flex flex-col">
        <div class="flex items-center justify-between mb-3">
            <h2 class="text-lg font-semibold text-foreground">
                Live Strategies
            </h2>
            <span class="text-xs text-muted-foreground font-mono">
                {{ enabledCount }}/{{ strategies.length }} active
            </span>
        </div>

        <!-- Filters -->
        <div class="flex items-center gap-3 mb-3">
            <div class="flex gap-1">
                <button
                    v-for="tab in marketTabs"
                    :key="tab.id"
                    class="px-2.5 py-1 text-sm rounded transition-colors"
                    :class="
                        activeTab === tab.id
                            ? 'bg-primary/10 text-primary'
                            : 'text-muted-foreground hover:text-foreground'
                    "
                    @click="activeTab = tab.id"
                >
                    {{ tab.label }}
                    <span
                        v-if="tabCount(tab.id) > 0"
                        class="ml-0.5 text-[10px] font-mono opacity-60"
                        >{{ tabCount(tab.id) }}</span
                    >
                </button>
            </div>

            <div class="w-px h-4 bg-border" />

            <div class="flex gap-1">
                <button
                    v-for="f in strategyFilters"
                    :key="f.value"
                    class="px-2.5 py-1 text-sm rounded transition-colors"
                    :class="
                        strategyFilter === f.value
                            ? 'bg-primary/10 text-primary'
                            : 'text-muted-foreground hover:text-foreground'
                    "
                    @click="strategyFilter = f.value"
                >
                    {{ f.label }}
                </button>
            </div>

            <div class="w-px h-4 bg-border" />

            <div class="flex gap-1">
                <button
                    v-for="f in statusFilters"
                    :key="f.value"
                    class="px-2.5 py-1 text-sm rounded transition-colors"
                    :class="
                        statusFilter === f.value
                            ? 'bg-primary/10 text-primary'
                            : 'text-muted-foreground hover:text-foreground'
                    "
                    @click="statusFilter = f.value"
                >
                    {{ f.label }}
                </button>
            </div>
        </div>

        <!-- Loading -->
        <div
            v-if="loading"
            class="flex-1 flex items-center justify-center text-sm text-muted-foreground"
        >
            Loading strategies...
        </div>

        <!-- Empty state -->
        <div
            v-else-if="sortedStrategies.length === 0"
            class="flex-1 flex items-center justify-center text-sm text-muted-foreground"
        >
            {{
                strategies.length === 0
                    ? "No strategies deployed yet. Deploy from the Backtests page."
                    : "No strategies match this filter."
            }}
        </div>

        <!-- Table -->
        <div v-else class="fr-card overflow-hidden flex-1 min-h-0">
            <div class="overflow-auto h-full">
                <table class="w-full text-sm">
                    <thead class="sticky top-0 bg-card z-10">
                        <tr class="border-b border-border">
                            <th
                                v-for="col in columns"
                                :key="col.key"
                                class="text-left px-3 py-2.5 text-[10px] font-medium uppercase tracking-wider text-muted-foreground whitespace-nowrap transition-colors"
                                :class="
                                    col.sortable
                                        ? 'cursor-pointer hover:text-foreground'
                                        : ''
                                "
                                @click="col.sortable && toggleSort(col.key)"
                            >
                                {{ col.label }}
                                <span
                                    v-if="sortKey === col.key"
                                    class="ml-0.5"
                                    >{{ sortDir === "asc" ? "↑" : "↓" }}</span
                                >
                            </th>
                            <th
                                class="px-3 py-2.5 text-[10px] font-medium uppercase tracking-wider text-muted-foreground w-8"
                            />
                        </tr>
                    </thead>
                    <tbody>
                        <tr
                            v-for="strategy in sortedStrategies"
                            :key="strategy.id"
                            class="border-b border-border transition-colors hover:bg-primary/[0.02]"
                        >
                            <!-- Instrument -->
                            <td class="px-3 py-2 whitespace-nowrap">
                                <span class="font-medium text-foreground">{{
                                    strategy.instrument.replace("_", "/")
                                }}</span>
                            </td>

                            <!-- Type -->
                            <td class="px-3 py-2 whitespace-nowrap">
                                <span
                                    class="text-[10px] px-1.5 py-0.5 rounded font-medium"
                                    :class="
                                        strategy.strategy_type ===
                                        'mean_reversion'
                                            ? 'bg-blue-500/10 text-blue-400'
                                            : 'bg-violet-500/10 text-violet-400'
                                    "
                                    >{{
                                        strategy.strategy_type ===
                                        "mean_reversion"
                                            ? "Mean Rev"
                                            : "Trend"
                                    }}</span
                                >
                            </td>

                            <!-- Timeframe -->
                            <td
                                class="px-3 py-2 whitespace-nowrap font-mono text-muted-foreground text-xs"
                            >
                                {{ strategy.granularity }}
                            </td>

                            <!-- Params -->
                            <td
                                class="px-3 py-2 whitespace-nowrap font-mono text-[11px] text-muted-foreground"
                            >
                                <template
                                    v-if="
                                        strategy.strategy_type ===
                                        'trend_following'
                                    "
                                >
                                    F{{ strategy.parameters.fast_period }}/S{{
                                        strategy.parameters.slow_period
                                    }}
                                    SL={{ pct(strategy.parameters.stop_loss) }}
                                    {{
                                        strategy.parameters.take_profit != null
                                            ? "TP=" +
                                              pct(
                                                  strategy.parameters
                                                      .take_profit,
                                              )
                                            : "TP=Ride"
                                    }}
                                </template>
                                <template v-else>
                                    MA{{ strategy.parameters.ma_period }} E={{
                                        pct(strategy.parameters.entry_threshold)
                                    }}
                                    X={{
                                        pct(strategy.parameters.exit_threshold)
                                    }}
                                    SL={{ pct(strategy.parameters.stop_loss) }}
                                </template>
                            </td>

                            <!-- Return -->
                            <td
                                class="px-3 py-2 whitespace-nowrap font-mono text-right"
                            >
                                <template v-if="strategy.backtest_stats">
                                    <span
                                        :class="
                                            strategy.backtest_stats
                                                .total_return >= 0
                                                ? 'text-emerald-400'
                                                : 'text-red-400'
                                        "
                                    >
                                        {{
                                            pct(
                                                strategy.backtest_stats
                                                    .total_return,
                                            )
                                        }}
                                    </span>
                                </template>
                                <span v-else class="text-muted-foreground/30"
                                    >—</span
                                >
                            </td>

                            <!-- Win Rate -->
                            <td
                                class="px-3 py-2 whitespace-nowrap font-mono text-foreground text-right"
                            >
                                <template v-if="strategy.backtest_stats">
                                    {{ pct(strategy.backtest_stats.win_rate) }}
                                </template>
                                <span v-else class="text-muted-foreground/30"
                                    >—</span
                                >
                            </td>

                            <!-- Sharpe -->
                            <td
                                class="px-3 py-2 whitespace-nowrap font-mono text-foreground text-right"
                            >
                                <template v-if="strategy.backtest_stats">
                                    {{
                                        strategy.backtest_stats.sharpe_ratio.toFixed(
                                            2,
                                        )
                                    }}
                                </template>
                                <span v-else class="text-muted-foreground/30"
                                    >—</span
                                >
                            </td>

                            <!-- Drawdown -->
                            <td
                                class="px-3 py-2 whitespace-nowrap font-mono text-red-400 text-right"
                            >
                                <template v-if="strategy.backtest_stats">
                                    {{
                                        pct(
                                            strategy.backtest_stats
                                                .max_drawdown,
                                        )
                                    }}
                                </template>
                                <span v-else class="text-muted-foreground/30"
                                    >—</span
                                >
                            </td>

                            <!-- Trades -->
                            <td
                                class="px-3 py-2 whitespace-nowrap font-mono text-foreground text-right"
                            >
                                <template v-if="strategy.backtest_stats">
                                    {{ strategy.backtest_stats.num_trades }}
                                </template>
                                <span v-else class="text-muted-foreground/30"
                                    >—</span
                                >
                            </td>

                            <!-- Status toggle -->
                            <td class="px-3 py-2 whitespace-nowrap">
                                <button
                                    @click="toggleStrategy(strategy)"
                                    :disabled="toggling === strategy.id"
                                    class="relative w-8 h-4 rounded-full transition-colors"
                                    :class="
                                        strategy.enabled
                                            ? 'bg-emerald-500/30'
                                            : 'bg-[#1a1a20]'
                                    "
                                >
                                    <span
                                        class="absolute top-0.5 w-3 h-3 rounded-full transition-all"
                                        :class="
                                            strategy.enabled
                                                ? 'left-[17px] bg-emerald-400'
                                                : 'left-0.5 bg-[#4a4a5a]'
                                        "
                                    />
                                </button>
                            </td>

                            <!-- Delete -->
                            <td class="px-1 py-2 whitespace-nowrap">
                                <button
                                    v-if="deleteConfirm !== strategy.id"
                                    @click="deleteConfirm = strategy.id"
                                    :disabled="deleting === strategy.id"
                                    class="text-muted-foreground/30 hover:text-red-400 transition-colors text-xs px-1"
                                    title="Delete"
                                >
                                    ✕
                                </button>
                                <div v-else class="flex items-center gap-1">
                                    <button
                                        @click="deleteStrategy(strategy)"
                                        class="text-[10px] text-red-400 hover:text-red-300 font-medium"
                                    >
                                        Del
                                    </button>
                                    <button
                                        @click="deleteConfirm = null"
                                        class="text-[10px] text-muted-foreground hover:text-foreground"
                                    >
                                        No
                                    </button>
                                </div>
                            </td>
                        </tr>
                    </tbody>
                </table>
            </div>
        </div>

        <!-- Error toast -->
        <div
            v-if="errorMessage"
            class="fixed bottom-6 right-6 bg-red-500/10 border border-red-500/20 text-red-400 text-sm px-4 py-2.5 rounded-lg"
        >
            {{ errorMessage }}
        </div>
    </main>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from "vue";
import { api } from "@/services/api";

interface BacktestStats {
    total_return: number;
    win_rate: number;
    sharpe_ratio: number;
    max_drawdown: number;
    num_trades: number;
    avg_win: number;
    avg_loss: number;
}

interface LiveStrategy {
    id: string;
    strategy_type: string;
    instrument: string;
    granularity: string;
    parameters: Record<string, any>;
    enabled: boolean;
    max_position_size: string;
    created_at: string;
    updated_at: string;
    backtest_run_id: string | null;
    backtest_stats: BacktestStats | null;
}

const instrumentCategories: Record<string, string> = {
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

function getCategory(instrument: string): string {
    return instrumentCategories[instrument] || "forex";
}

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

const marketTabs = [
    { id: "all", label: "All" },
    { id: "forex", label: "Forex" },
    { id: "metals", label: "Metals" },
    { id: "commodities", label: "Commodities" },
    { id: "indices", label: "Indices" },
    { id: "bonds", label: "Bonds" },
];

const strategyFilters = [
    { value: "all", label: "All" },
    { value: "mean_reversion", label: "Mean Reversion" },
    { value: "trend_following", label: "Trend Following" },
];

const statusFilters = [
    { value: "all", label: "All" },
    { value: "enabled", label: "Active" },
    { value: "disabled", label: "Inactive" },
];

const columns = [
    { key: "instrument", label: "Pair", sortable: true },
    { key: "strategy_type", label: "Type", sortable: true },
    { key: "granularity", label: "TF", sortable: false },
    { key: "params", label: "Parameters", sortable: false },
    { key: "total_return", label: "Return", sortable: true },
    { key: "win_rate", label: "Win%", sortable: true },
    { key: "sharpe_ratio", label: "Sharpe", sortable: true },
    { key: "max_drawdown", label: "DD", sortable: true },
    { key: "num_trades", label: "#", sortable: true },
    { key: "enabled", label: "Live", sortable: true },
];

const filteredStrategies = computed(() => {
    let filtered = strategies.value;
    if (activeTab.value !== "all") {
        filtered = filtered.filter(
            (s) => getCategory(s.instrument) === activeTab.value,
        );
    }
    if (strategyFilter.value !== "all") {
        filtered = filtered.filter(
            (s) => s.strategy_type === strategyFilter.value,
        );
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
        let aVal: any, bVal: any;

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
            default:
                aVal = a.instrument;
                bVal = b.instrument;
        }

        if (typeof aVal === "string") {
            return sortDir.value === "asc"
                ? aVal.localeCompare(bVal)
                : bVal.localeCompare(aVal);
        }
        return sortDir.value === "asc" ? aVal - bVal : bVal - aVal;
    });
    return sorted;
});

const enabledCount = computed(
    () => strategies.value.filter((s) => s.enabled).length,
);

function tabCount(tabId: string): number {
    if (tabId === "all") return strategies.value.length;
    return strategies.value.filter((s) => getCategory(s.instrument) === tabId)
        .length;
}

function toggleSort(key: string) {
    if (sortKey.value === key) {
        sortDir.value = sortDir.value === "asc" ? "desc" : "asc";
    } else {
        sortKey.value = key;
        sortDir.value =
            key === "instrument" || key === "strategy_type" ? "asc" : "desc";
    }
}

function pct(value: number): string {
    return (value * 100).toFixed(2) + "%";
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
        const data = await api.post<{ id: string; enabled: boolean }>(
            `/live/strategies/${strategy.id}/toggle`,
            {},
        );
        strategy.enabled = data.enabled;
    } catch (e: any) {
        showError("Failed to toggle strategy");
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
    } catch (e: any) {
        const msg = e?.response?.data?.error || "Failed to delete strategy";
        showError(msg);
        console.error("Delete failed:", e);
    } finally {
        deleting.value = null;
    }
}

async function loadStrategies() {
    loading.value = true;
    try {
        const data = await api.get<{
            strategies: LiveStrategy[];
            count: number;
        }>("/live/strategies");
        strategies.value = data.strategies;
    } catch (e) {
        console.error("Failed to load strategies:", e);
    } finally {
        loading.value = false;
    }
}

onMounted(() => {
    loadStrategies();
});
</script>
