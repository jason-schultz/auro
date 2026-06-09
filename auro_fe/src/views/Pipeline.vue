<template>
    <main class="p-6 h-[calc(100vh-57px)] flex flex-col">
        <ViewHeader title="Pipeline">
            <template #actions>
            <FilterToolbar :inline="true" :tight="true">
                <FilterSelect v-model="filterStrategy" :options="strategyOptions" placeholder="All strategies" />
                <FilterSelect v-model="filterGranularity" :options="granularityOptions" placeholder="All granularities" />
                <FilterSelect v-model="filterStatus" :options="statusOptions" placeholder="All statuses" />
                <FilterSelect v-model="filterSource" :options="sourceOptions" placeholder="All sources" />
                <button
                    @click="load"
                    class="px-3 py-1.5 text-sm rounded bg-primary/10 text-primary hover:bg-primary/20 transition-colors"
                >
                    Refresh
                </button>
            </FilterToolbar>
            </template>
        </ViewHeader>

        <!-- Summary pills -->
        <div v-if="summary" class="fr-card p-3 mb-4">
            <div class="flex items-center gap-6 text-sm font-mono">
                <span class="text-muted-foreground">Total: <span class="text-foreground">{{ summary.total }}</span></span>
                <span class="text-yellow-400">Running: {{ summary.running }}</span>
                <span class="text-emerald-400">Passed: {{ summary.passed }}</span>
                <span class="text-red-400">Failed: {{ summary.failed }}</span>
                <span class="text-muted-foreground">Pending: {{ summary.pending }}</span>
                <span class="text-border">|</span>
                <span class="text-muted-foreground">Backtest: <span class="text-foreground">{{ summary.backtest }}</span></span>
                <span class="text-muted-foreground">Walk-fwd: <span class="text-foreground">{{ summary.walk_forward }}</span></span>
                <span class="text-muted-foreground">Monte Carlo: <span class="text-foreground">{{ summary.monte_carlo }}</span></span>
            </div>
        </div>

        <!-- Table -->
        <DataTableScaffold
            :loading="loading"
            :empty="sorted.length === 0"
            empty-message="No configs found."
            head-class="sticky top-0 bg-card border-b border-border z-40"
            head-row-class="text-left text-muted-foreground"
            content-class="overflow-auto flex-1"
            table-class="w-full min-w-max text-sm"
        >
            <template #head>
                <th
                    v-for="(col, idx) in tableColumns"
                    :key="col.key"
                    class="px-3 py-2 text-[10px] font-medium uppercase tracking-wider whitespace-nowrap"
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
                        <span v-if="col.sortable && sortKey === col.key" class="ml-0.5">
                            {{ sortDir === "asc" ? "↑" : "↓" }}
                        </span>
                    </button>
                </th>
            </template>
            <template #body>
                        <tr
                            v-for="c in sorted"
                            :key="c.config_id"
                            class="group border-b border-border/40 hover:bg-muted/20 transition-colors"
                        >
                            <td :class="cellClass('instrument', c, 0, 'font-mono text-foreground')">
                                {{ c.instrument.replace("_", "/") }}
                            </td>
                            <td :class="cellClass('strategy_type', c, 1, 'text-muted-foreground')">
                                <StrategyTypeBadge :type="c.strategy_type" />
                            </td>
                            <td :class="cellClass('granularity', c, 2, 'text-xs text-muted-foreground')">
                                {{ c.granularity }}
                            </td>
                            <td :class="cellClass('variant', c, 3, 'text-xs text-muted-foreground')">
                                {{ variantLabel(c) }}
                            </td>
                            <td :class="cellClass('generation', c, 4, 'text-xs')">
                                <template v-if="c.evo_generation != null">
                                    <span class="text-primary">G{{ c.evo_generation }}</span>
                                    <span class="text-muted-foreground"> C{{ childRank(c) }}</span>
                                </template>
                                <template v-else-if="c.depth > 0">
                                    <span class="text-muted-foreground">d{{ c.depth }}</span>
                                </template>
                                <template v-else>
                                    <span class="text-muted-foreground">—</span>
                                </template>
                            </td>
                            <td :class="cellClass('stage', c, 5, 'text-muted-foreground text-xs')">
                                {{ stageLabel(c.stage) }}
                            </td>
                            <td :class="cellClass('status', c, 6)">
                                <StatusBadge :status="c.status" />
                            </td>
                            <td :class="cellClass('sharpe', c, 7, `text-xs ${sharpeColor(sharpeStat(c))}`)">
                                {{ fmt(sharpeStat(c)) }}
                            </td>
                            <td :class="cellClass('trades', c, 8, 'text-xs text-muted-foreground')">
                                {{ tradesStat(c) ?? "—" }}
                            </td>
                            <td :class="cellClass('drawdown', c, 9, 'text-xs text-red-400')">
                                {{ formatTablePercent(drawdownStat(c), { decimals: 1 }) }}
                            </td>
                            <td :class="cellClass('score', c, 10, `text-xs ${scoreColor(c.score)}`)">
                                {{ c.score != null ? c.score.toFixed(3) : "—" }}
                            </td>
                            <td :class="cellClass('failure_reason', c, 11, 'text-xs text-muted-foreground max-w-50 truncate')" :title="c.failure_reason ?? undefined">
                                {{ c.failure_reason || "—" }}
                            </td>
                        </tr>
            </template>
        </DataTableScaffold>
    </main>
</template>

<script setup lang="ts">
import { usePipeline } from "@/composables/usePipeline";
import FilterSelect from "@/components/ui/FilterSelect.vue";
import FilterToolbar from "@/components/ui/FilterToolbar.vue";
import DataTableScaffold from "@/components/ui/DataTableScaffold.vue";
import StatusBadge from "@/components/ui/StatusBadge.vue";
import StrategyTypeBadge from "@/components/ui/StrategyTypeBadge.vue";
import ViewHeader from "@/components/ui/ViewHeader.vue";
import {
    PIPELINE_COLUMNS,
    ariaSortForColumn,
    formatTablePercent,
    stickyFirstColumnClass,
    tableCellAlignClass,
    tableHeaderAlignClass,
    tableWidthClass,
} from "@/lib/ui";
import type { PipelineConfig } from "@/types/pipeline";

const strategyOptions = [
    { value: "trend_following", label: "Trend Following" },
    { value: "mean_reversion", label: "Mean Reversion" },
    { value: "donchian", label: "Donchian" },
    { value: "macd", label: "MACD" },
];

const granularityOptions = [
    { value: "H1", label: "H1" },
    { value: "H4", label: "H4" },
    { value: "M15", label: "M15" },
    { value: "M5", label: "M5" },
];

const statusOptions = [
    { value: "pending", label: "Pending" },
    { value: "running", label: "Running" },
    { value: "passed", label: "Passed" },
    { value: "failed", label: "Failed" },
];

const sourceOptions = [
    { value: "evo", label: "Evo only" },
    { value: "manual", label: "Manual" },
];

const {
    loading,
    summary,
    filterStrategy,
    filterGranularity,
    filterStatus,
    filterSource,
    sorted,
    sortKey,
    sortDir,
    childRank,
    load,
    toggleSort,
    variantLabel,
    stageLabel,
    sharpeStat,
    tradesStat,
    drawdownStat,
    sharpeColor,
    scoreColor,
    fmt,
} = usePipeline();

const tableColumns = PIPELINE_COLUMNS;

function headerClass(key: string, columnIndex: number, sortable: boolean): string {
    return [
        tableWidthClass("pipeline", key),
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

function cellClass(
    key: string,
    _row: PipelineConfig,
    columnIndex: number,
    extraClass = "",
): string {
    return [
        "px-3 py-2 font-mono",
        tableWidthClass("pipeline", key),
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
