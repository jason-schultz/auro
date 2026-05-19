<template>
    <main class="p-6 h-[calc(100vh-57px)] flex flex-col">
        <ViewHeader title="Live Strategies" :compact="true">
            <template #actions>
                <span class="text-xs text-muted-foreground font-mono">
                    {{ enabledCount }}/{{ strategies.length }} active
                </span>
            </template>
        </ViewHeader>

        <!-- Filters -->
        <FilterToolbar>
            <SegmentedFilterGroup
                v-model="activeTab"
                :options="marketTabs"
                :counts="marketTabCounts"
                active-class="bg-primary/10 text-primary"
                inactive-class="text-muted-foreground hover:text-foreground"
            />

            <FilterToolbarDivider />

            <SegmentedFilterGroup
                v-model="strategyFilter"
                :options="strategyFilters"
                active-class="bg-primary/10 text-primary"
                inactive-class="text-muted-foreground hover:text-foreground"
            />

            <FilterToolbarDivider />

            <SegmentedFilterGroup
                v-model="statusFilter"
                :options="statusFilters"
                active-class="bg-primary/10 text-primary"
                inactive-class="text-muted-foreground hover:text-foreground"
            />
        </FilterToolbar>

        <DataTableScaffold
            :loading="loading"
            :empty="sortedStrategies.length === 0"
            :empty-message="strategies.length === 0 ? 'No strategies deployed yet.' : 'No strategies match this filter.'"
            card-class="min-h-0"
            content-class="overflow-auto h-full"
            table-class="w-full min-w-max text-sm"
            head-class="sticky top-0 bg-card z-40"
            head-row-class="border-b border-border"
        >
            <template #head>
                            <th
                                v-for="(col, idx) in columns"
                                :key="col.key"
                                class="px-3 py-2.5 text-[10px] font-medium uppercase tracking-wider text-muted-foreground whitespace-nowrap"
                                :class="headerClass(col.key, idx, col.sortable)"
                                :aria-sort="ariaSortForColumn({ sortable: col.sortable, columnKey: col.key, sortKey, sortDir })"
                            >
                                <button
                                    type="button"
                                    class="inline-flex items-center gap-0.5 transition-colors"
                                    :class="col.sortable ? 'cursor-pointer hover:text-foreground' : 'cursor-default'"
                                    :disabled="!col.sortable"
                                    @click="col.sortable && toggleSort(col.key)"
                                >
                                    {{ col.label }}
                                    <span
                                        v-if="col.sortable && sortKey === col.key"
                                        class="ml-0.5"
                                        >{{ sortDir === "asc" ? "↑" : "↓" }}</span
                                    >
                                </button>
                            </th>
                            <th
                                class="px-3 py-2.5 text-[10px] font-medium uppercase tracking-wider text-muted-foreground w-8"
                                :class="tableWidthClass('strategies', 'actions')"
                            />
            </template>
            <template #body>
                        <tr
                            v-for="strategy in sortedStrategies"
                            :key="strategy.id"
                            class="group border-b border-border transition-colors hover:bg-primary/2"
                        >
                            <!-- Instrument -->
                            <td :class="cellClass('instrument', 0, 'font-medium text-foreground')">
                                <span class="font-medium text-foreground">{{
                                    strategy.instrument.replace("_", "/")
                                }}</span>
                            </td>

                            <!-- Type + source badge -->
                            <td :class="cellClass('strategy_type', 1)">
                                <div class="flex items-center gap-1">
                                    <StrategyTypeBadge :type="strategy.strategy_type" />
                                    <BadgePill
                                        v-if="strategy.source === 'evolution'"
                                        label="Evo"
                                        size="2xs"
                                        :extra-class="'bg-amber-500/10 text-amber-400'"
                                        :title="strategy.pipeline_score != null ? 'Evo score: ' + strategy.pipeline_score.toFixed(3) : 'Evolutionary pipeline'"
                                    />
                                    <BadgePill
                                        v-else-if="strategy.source === 'pipeline' || strategy.source === 'ollama' || strategy.source === 'manual' || strategy.source === 'reseed'"
                                        label="Pipeline"
                                        size="2xs"
                                        :extra-class="'bg-muted text-muted-foreground'"
                                        title="Promoted via pipeline"
                                    />
                                </div>
                            </td>

                            <!-- Timeframe -->
                            <td :class="cellClass('granularity', 2, 'text-xs text-muted-foreground')">
                                {{ strategy.granularity }}
                            </td>

                            <!-- Params -->
                            <td :class="cellClass('params', 3, 'text-[11px] text-muted-foreground')">
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
                            <td :class="cellClass('total_return', 4)">
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
                            <td :class="cellClass('win_rate', 5, 'text-foreground')">
                                <template v-if="strategy.backtest_stats">
                                    {{ pct(strategy.backtest_stats.win_rate) }}
                                </template>
                                <span v-else class="text-muted-foreground/30"
                                    >—</span
                                >
                            </td>

                            <!-- Sharpe -->
                            <td :class="cellClass('sharpe_ratio', 6, 'text-foreground')">
                                <template v-if="strategy.backtest_stats">
                                    {{
                                        num(strategy.backtest_stats.sharpe_ratio)
                                    }}
                                </template>
                                <span v-else class="text-muted-foreground/30"
                                    >—</span
                                >
                            </td>

                            <!-- OOS Sharpe (pipeline only) -->
                            <td :class="cellClass('oos_sharpe', 7)">
                                <template v-if="strategy.oos_stats">
                                    <span :class="strategy.oos_stats.oos_sharpe >= 0.5 ? 'text-emerald-400' : strategy.oos_stats.oos_sharpe >= 0.15 ? 'text-primary' : 'text-red-400'">
                                        {{ num(strategy.oos_stats.oos_sharpe) }}
                                    </span>
                                    <span class="text-muted-foreground/50 text-[10px] ml-1">{{ strategy.oos_stats.oos_num_trades }}t</span>
                                </template>
                                <span v-else class="text-muted-foreground/30">—</span>
                            </td>

                            <!-- Drawdown -->
                            <td :class="cellClass('max_drawdown', 8, 'text-red-400')">
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
                            <td :class="cellClass('num_trades', 9, 'text-foreground')">
                                <template v-if="strategy.backtest_stats">
                                    {{ strategy.backtest_stats.num_trades }}
                                </template>
                                <span v-else class="text-muted-foreground/30"
                                    >—</span
                                >
                            </td>

                            <!-- Live # trades -->
                            <td :class="cellClass('live_num_trades', 10, 'text-foreground')">
                                <template v-if="strategy.live_stats">
                                    {{ strategy.live_stats.num_trades }}
                                </template>
                                <span v-else class="text-muted-foreground/30"
                                    >—</span
                                >
                            </td>

                            <!-- Live Win Rate -->
                            <td :class="cellClass('live_win_rate', 11)">
                                <template v-if="strategy.live_stats">
                                    <span class="text-foreground">{{
                                        pct(strategy.live_stats.win_rate)
                                    }}</span>
                                    <span
                                        v-if="
                                            strategy.backtest_stats &&
                                            strategy.live_stats.num_trades >= 5
                                        "
                                        class="text-[10px] ml-1"
                                        :class="
                                            winRateDeltaClass(strategy)
                                        "
                                        >{{ winRateDeltaLabel(strategy) }}</span
                                    >
                                </template>
                                <span v-else class="text-muted-foreground/30"
                                    >—</span
                                >
                            </td>

                            <!-- Edge status -->
                            <td :class="cellClass('edge', 12)">
                                <BadgePill
                                    :label="edgeStatus(strategy).label"
                                    :extra-class="edgeStatus(strategy).color"
                                />
                            </td>

                            <!-- Status toggle -->
                            <td :class="cellClass('enabled', 13)">
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
                                                ? 'left-4.25 bg-emerald-400'
                                                : 'left-0.5 bg-[#4a4a5a]'
                                        "
                                    />
                                </button>
                            </td>

                            <!-- Delete -->
                            <td class="px-1 py-2 whitespace-nowrap" :class="tableWidthClass('strategies', 'actions')">
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
            </template>
        </DataTableScaffold>

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
import { computed, onMounted } from "vue";
import { useStrategies } from "@/composables/useStrategies";
import BadgePill from "@/components/ui/BadgePill.vue";
import StrategyTypeBadge from "@/components/ui/StrategyTypeBadge.vue";
import SegmentedFilterGroup from "@/components/ui/SegmentedFilterGroup.vue";
import FilterToolbar from "@/components/ui/FilterToolbar.vue";
import FilterToolbarDivider from "@/components/ui/FilterToolbarDivider.vue";
import DataTableScaffold from "@/components/ui/DataTableScaffold.vue";
import ViewHeader from "@/components/ui/ViewHeader.vue";
import {
    ariaSortForColumn,
    stickyFirstColumnClass,
    tableCellAlignClass,
    tableHeaderAlignClass,
    tableWidthClass,
} from "@/lib/ui";

const {
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
    sortedStrategies,
    enabledCount,
    tabCount,
    toggleSort,
    pct,
    num,
    winRateDeltaLabel,
    winRateDeltaClass,
    edgeStatus,
    toggleStrategy,
    deleteStrategy,
    loadStrategies,
} = useStrategies();

const marketTabCounts = computed(() => {
    return Object.fromEntries(marketTabs.map((tab) => [tab.id, tabCount(tab.id)]));
});

onMounted(() => {
    loadStrategies();
});

function headerClass(key: string, columnIndex: number, sortable: boolean): string {
    return [
        tableWidthClass("strategies", key),
        tableHeaderAlignClass(key),
        sortable ? "cursor-pointer hover:text-foreground transition-colors" : "",
        stickyFirstColumnClass({
            isFirst: columnIndex === 0,
            isHeader: true,
        }),
    ]
        .filter(Boolean)
        .join(" ");
}

function cellClass(key: string, columnIndex: number, extraClass = ""): string {
    return [
        "px-3 py-2 whitespace-nowrap font-mono",
        tableWidthClass("strategies", key),
        tableCellAlignClass(key),
        extraClass,
        stickyFirstColumnClass({
            isFirst: columnIndex === 0,
            isHeader: false,
        }),
    ]
        .filter(Boolean)
        .join(" ");
}
</script>
