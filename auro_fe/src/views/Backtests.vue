<template>
    <main class="p-6 h-[calc(100vh-57px)] flex flex-col">
        <ViewHeader title="Backtest Results">
            <template #actions>
            <FilterToolbar v-if="sourceFilter === 'grid'" :inline="true" :tight="true">
                <select
                    v-model="runInstrument"
                    class="bg-background text-foreground text-sm rounded px-2 py-1 border border-border focus:outline-none focus:border-primary/30"
                >
                    <option
                        v-for="inst in instruments"
                        :key="inst"
                        :value="inst"
                    >
                        {{ inst.replace("_", "/") }}
                    </option>
                </select>
                <select
                    v-model="runTimeframe"
                    class="bg-background text-foreground text-sm rounded px-2 py-1 border border-border focus:outline-none focus:border-primary/30"
                >
                    <option value="M15">15m</option>
                    <option value="H1">1H</option>
                    <option value="H4">4H</option>
                    <option value="D">Daily</option>
                </select>
                <button
                    @click="runGridSearch"
                    :disabled="running"
                    class="px-4 py-1.5 text-sm rounded transition-colors"
                    :class="
                        running
                            ? 'bg-muted text-muted-foreground cursor-not-allowed'
                            : 'bg-primary/10 text-primary hover:bg-primary/20'
                    "
                >
                    {{ running ? "Running..." : "Run Grid Search" }}
                </button>
            </FilterToolbar>
            </template>
        </ViewHeader>

        <!-- Run result banner -->
        <div v-if="lastRunResult" class="fr-card p-3 mb-4">
            <div class="flex items-center justify-between text-sm">
                <div class="text-foreground">
                    Grid search:
                    <span class="font-mono">{{
                        lastRunResult.instrument.replace("_", "/")
                    }}</span>
                    on
                    <span class="font-mono">{{ lastRunResult.timeframe }}</span>
                </div>
                <div class="flex items-center gap-4 font-mono text-xs">
                    <span class="text-emerald-400"
                        >{{ lastRunResult.results.valid }} valid</span
                    >
                    <span class="text-primary"
                        >{{ lastRunResult.results.verify }} verify</span
                    >
                    <span class="text-muted-foreground"
                        >{{ lastRunResult.results.failed }} failed</span
                    >
                </div>
            </div>
        </div>

        <!-- Source + Filters -->
        <FilterToolbar>
            <SegmentedFilterGroup
                :model-value="sourceFilter"
                :options="sourceOptions"
                active-class="bg-primary/10 text-primary"
                inactive-class="text-muted-foreground hover:text-foreground"
                @update:model-value="(value) => { sourceFilter = value as 'grid' | 'pipeline'; loadResults(); }"
            />

            <FilterToolbarDivider />
        </FilterToolbar>

        <FilterToolbar>
            <template v-if="sourceFilter === 'grid'">
                <SegmentedFilterGroup
                    :model-value="statusFilter"
                    :options="statusFilters"
                    active-class="bg-primary/10 text-primary"
                    inactive-class="text-muted-foreground hover:text-foreground"
                    @update:model-value="(value) => { statusFilter = value; loadResults(); }"
                />

                <FilterToolbarDivider />
            </template>

            <SegmentedFilterGroup
                :model-value="strategyFilter"
                :options="strategyFilters"
                active-class="bg-primary/10 text-primary"
                inactive-class="text-muted-foreground hover:text-foreground"
                @update:model-value="(value) => { strategyFilter = value; loadResults(); }"
            />

            <FilterToolbarDivider />

            <SegmentedFilterGroup
                :model-value="granularityFilter"
                :options="granularityFilters"
                active-class="bg-primary/10 text-primary"
                inactive-class="text-muted-foreground hover:text-foreground"
                @update:model-value="(value) => { granularityFilter = value; loadResults(); }"
            />

            <FilterSelect
                :model-value="instrumentFilter"
                :options="instrumentOptions"
                placeholder="All instruments"
                @update:model-value="(value) => { instrumentFilter = value; loadResults(); }"
            />
        </FilterToolbar>

        <!-- Main content: table + detail panel -->
        <div class="flex gap-4 flex-1 min-h-0">
            <!-- Results table -->
            <div class="w-[55%] min-h-0">
                <DataTableScaffold
                    :loading="loading"
                    :empty="results.length === 0"
                    loading-message="Loading results..."
                    empty-message="No results found."
                    card-class="h-full"
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
                            :class="headerClass(col.key, idx)"
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
                                    >{{
                                        sortDir === "asc" ? "↑" : "↓"
                                    }}</span
                                >
                            </button>
                        </th>
                    </template>
                    <template #body>
                            <tr
                                v-for="row in sortedResults"
                                :key="row.id"
                                class="group border-b border-border transition-colors cursor-pointer"
                                :class="
                                    selectedRun?.id === row.id
                                        ? 'bg-primary/5'
                                        : 'hover:bg-primary/2'
                                "
                                @click="selectRun(row)"
                            >
                                <td
                                    v-for="(col, idx) in columns"
                                    :key="col.key"
                                    class="px-3 py-2 whitespace-nowrap"
                                    :class="cellClass(col.key, row, idx)"
                                >
                                    <span
                                        v-if="col.key === 'status'"
                                        class="inline-flex"
                                    >
                                        <StatusBadge :status="row.status" :label="row.status" />
                                    </span>
                                    <template v-else>{{
                                        cellValue(col.key, row)
                                    }}</template>
                                </td>
                            </tr>
                    </template>
                </DataTableScaffold>
            </div>

            <!-- Detail panel — always visible -->
            <div class="w-[45%] flex flex-col gap-4 overflow-y-auto">
                <!-- Empty state -->
                <div
                    v-if="!selectedRun"
                    class="fr-card p-8 flex-1 flex items-center justify-center"
                >
                    <StateMessage message="Select a backtest run to view details" />
                </div>

                <template v-else>
                    <!-- Stats -->
                    <div class="fr-card p-4">
                        <div class="flex items-center justify-between mb-3">
                            <div class="fr-section-label mb-0 pb-0 border-b-0">
                                {{ selectedRun.strategy_name }}
                            </div>
                            <div class="flex items-center gap-2">
                                <template
                                    v-if="
                                        selectedRun.status === 'valid' ||
                                        (selectedRun._pipeline &&
                                            selectedRun.status === 'passed')
                                    "
                                >
                                    <div class="flex items-center gap-1">
                                        <span
                                            class="text-[10px] text-muted-foreground"
                                            >Units</span
                                        >
                                        <input
                                            v-model="deployUnits"
                                            type="text"
                                            class="w-16 bg-background text-foreground text-xs font-mono rounded px-1.5 py-1 border border-border focus:outline-none focus:border-primary/30 text-right"
                                        />
                                    </div>
                                    <button
                                        @click="
                                            selectedRun._pipeline
                                                ? promoteStrategy()
                                                : deployStrategy()
                                        "
                                        :disabled="deploying"
                                        class="px-3 py-1 text-xs rounded transition-colors"
                                        :class="
                                            deploying
                                                ? 'bg-muted text-muted-foreground cursor-not-allowed'
                                                : 'bg-emerald-500/10 text-emerald-400 hover:bg-emerald-500/20'
                                        "
                                    >
                                        {{
                                            deploying
                                                ? "Promoting..."
                                                : selectedRun._pipeline
                                                  ? "Promote"
                                                  : "Deploy"
                                        }}
                                    </button>
                                </template>
                                <button
                                    @click="
                                        selectedRun = null;
                                        selectedTrades = [];
                                        deployMessage = '';
                                    "
                                    class="text-muted-foreground hover:text-foreground text-xs"
                                >
                                    ✕
                                </button>
                            </div>
                        </div>

                        <!-- Deploy feedback message -->
                        <div
                            v-if="deployMessage"
                            class="mb-3 text-xs px-2.5 py-1.5 rounded"
                            :class="
                                deployError
                                    ? 'bg-red-500/10 text-red-400'
                                    : 'bg-emerald-500/10 text-emerald-400'
                            "
                        >
                            {{ deployMessage }}
                        </div>

                        <div class="grid grid-cols-4 gap-2 mb-3">
                            <div class="bg-background rounded-md p-2">
                                <div class="text-[10px] text-muted-foreground">
                                    Return
                                </div>
                                <div
                                    class="text-sm font-mono font-medium"
                                    :class="
                                        selectedRun.total_return >= 0
                                            ? 'text-emerald-400'
                                            : 'text-red-400'
                                    "
                                >
                                    {{ pct(selectedRun.total_return) }}
                                </div>
                            </div>
                            <div class="bg-background rounded-md p-2">
                                <div class="text-[10px] text-muted-foreground">
                                    Win Rate
                                </div>
                                <div
                                    class="text-sm font-mono font-medium text-foreground"
                                >
                                    {{ pct(selectedRun.win_rate) }}
                                </div>
                            </div>
                            <div class="bg-background rounded-md p-2">
                                <div class="text-[10px] text-muted-foreground">
                                    Sharpe
                                </div>
                                <div
                                    class="text-sm font-mono font-medium text-foreground"
                                >
                                    {{ selectedRun.sharpe_ratio.toFixed(3) }}
                                </div>
                            </div>
                            <div class="bg-background rounded-md p-2">
                                <div class="text-[10px] text-muted-foreground">
                                    Drawdown
                                </div>
                                <div
                                    class="text-sm font-mono font-medium text-red-400"
                                >
                                    {{ pct(selectedRun.max_drawdown) }}
                                </div>
                            </div>
                        </div>

                        <div class="grid grid-cols-4 gap-2 mb-3">
                            <div class="bg-background rounded-md p-2">
                                <div class="text-[10px] text-muted-foreground">
                                    Avg Win
                                </div>
                                <div
                                    class="text-sm font-mono font-medium text-emerald-400"
                                >
                                    {{ pct(selectedRun.avg_win) }}
                                </div>
                            </div>
                            <div class="bg-background rounded-md p-2">
                                <div class="text-[10px] text-muted-foreground">
                                    Avg Loss
                                </div>
                                <div
                                    class="text-sm font-mono font-medium text-red-400"
                                >
                                    {{ pct(selectedRun.avg_loss) }}
                                </div>
                            </div>
                            <div class="bg-background rounded-md p-2">
                                <div class="text-[10px] text-muted-foreground">
                                    Trades
                                </div>
                                <div
                                    class="text-sm font-mono font-medium text-foreground"
                                >
                                    {{ selectedRun.num_trades }}
                                </div>
                            </div>
                            <div class="bg-background rounded-md p-2">
                                <div class="text-[10px] text-muted-foreground">
                                    Time
                                </div>
                                <div
                                    class="text-sm font-mono font-medium text-muted-foreground"
                                >
                                    {{ selectedRun.execution_duration_ms }}ms
                                </div>
                            </div>
                        </div>

                        <div
                            class="text-[10px] font-mono text-muted-foreground"
                        >
                            <template
                                v-if="
                                    selectedRun.strategy_type ===
                                    'trend_following'
                                "
                            >
                                Fast={{
                                    selectedRun.parameters.fast_period
                                }}
                                Slow={{
                                    selectedRun.parameters.slow_period
                                }}
                                Stop={{ pct(selectedRun.parameters.stop_loss) }}
                                <template
                                    v-if="
                                        selectedRun.parameters.take_profit !=
                                        null
                                    "
                                >
                                    TP={{
                                        pct(selectedRun.parameters.take_profit)
                                    }}
                                </template>
                                <template v-else>TP=Ride</template>
                            </template>
                            <template v-else>
                                MA={{
                                    selectedRun.parameters.ma_period
                                }}
                                Entry={{
                                    pct(selectedRun.parameters.entry_threshold)
                                }}
                                Exit={{
                                    pct(selectedRun.parameters.exit_threshold)
                                }}
                                Stop={{ pct(selectedRun.parameters.stop_loss) }}
                            </template>
                        </div>

                        <div
                            v-if="selectedRun.reason_flagged"
                            class="mt-2 text-xs text-primary"
                        >
                            ⚠ {{ selectedRun.reason_flagged }}
                        </div>
                    </div>

                    <!-- Pipeline stage breakdown (pipeline source only) -->
                    <template v-if="selectedRun._pipeline">
                        <div class="fr-card p-4">
                            <div class="fr-section-label mb-3">Pipeline Stages</div>
                            <div class="space-y-2">
                                <div
                                    v-for="stage in pipelineStageRows"
                                    :key="stage.key"
                                    class="bg-background rounded-md p-3"
                                >
                                    <div class="flex items-center justify-between mb-2">
                                        <span class="text-xs font-medium text-foreground capitalize">
                                            {{ stage.label }}
                                        </span>
                                        <StatusBadge :status="stage.status" />
                                    </div>
                                    <div
                                        v-if="stage.metrics.length > 0"
                                        class="grid grid-cols-3 gap-2 text-[10px] font-mono text-muted-foreground"
                                    >
                                        <span
                                            v-for="metric in stage.metrics"
                                            :key="`${stage.key}-${metric.label}`"
                                        >
                                            {{ metric.label }}: {{ metric.value }}
                                        </span>
                                    </div>
                                    <div
                                        v-else-if="stage.failureReason"
                                        class="text-[10px] font-mono text-red-400 mt-1"
                                    >
                                        {{ stage.failureReason }}
                                    </div>
                                    <div v-else class="text-[10px] text-muted-foreground">
                                        Not reached
                                    </div>
                                </div>
                            </div>
                        </div>
                    </template>

                    <!-- Equity curve (grid source only) -->
                    <div v-if="!selectedRun._pipeline" class="fr-card p-4">
                        <div class="fr-section-label mb-3">Equity Curve</div>
                        <StateMessage
                            v-if="loadingTrades"
                            message="Loading trades..."
                            :compact="true"
                        />
                        <StateMessage
                            v-else-if="selectedTrades.length === 0"
                            message="No trade data"
                            :compact="true"
                        />
                        <div
                            v-else
                            ref="chartWrapper"
                            class="w-full"
                            style="height: 200px"
                        >
                            <canvas ref="chartCanvas" class="w-full h-full" />
                        </div>
                    </div>

                    <!-- Trade list (grid source only) -->
                    <div v-if="!selectedRun._pipeline" class="fr-card p-4">
                        <div class="fr-section-label mb-3">Trades</div>
                        <StateMessage
                            v-if="selectedTrades.length === 0"
                            message="No trades"
                            :compact="true"
                        />
                        <div v-else class="overflow-auto max-h-75">
                            <table class="w-full text-xs">
                                <thead class="sticky top-0 bg-card">
                                    <tr class="border-b border-border">
                                        <th
                                            class="text-left px-2 py-1.5 text-[10px] text-muted-foreground uppercase"
                                        >
                                            Entry
                                        </th>
                                        <th
                                            class="text-left px-2 py-1.5 text-[10px] text-muted-foreground uppercase"
                                        >
                                            Exit
                                        </th>
                                        <th
                                            class="text-right px-2 py-1.5 text-[10px] text-muted-foreground uppercase"
                                        >
                                            Entry $
                                        </th>
                                        <th
                                            class="text-right px-2 py-1.5 text-[10px] text-muted-foreground uppercase"
                                        >
                                            Exit $
                                        </th>
                                        <th
                                            class="text-right px-2 py-1.5 text-[10px] text-muted-foreground uppercase"
                                        >
                                            P&L
                                        </th>
                                        <th
                                            class="text-right px-2 py-1.5 text-[10px] text-muted-foreground uppercase"
                                        >
                                            Reason
                                        </th>
                                    </tr>
                                </thead>
                                <tbody>
                                    <tr
                                        v-for="trade in selectedTrades"
                                        :key="trade.id"
                                        class="border-b border-border"
                                    >
                                        <td
                                            class="px-2 py-1.5 font-mono text-muted-foreground"
                                        >
                                            {{ formatDate(trade.entry_time) }}
                                        </td>
                                        <td
                                            class="px-2 py-1.5 font-mono text-muted-foreground"
                                        >
                                            {{ formatDate(trade.exit_time) }}
                                        </td>
                                        <td
                                            class="px-2 py-1.5 font-mono text-foreground text-right"
                                        >
                                            {{ trade.entry_price.toFixed(5) }}
                                        </td>
                                        <td
                                            class="px-2 py-1.5 font-mono text-foreground text-right"
                                        >
                                            {{ trade.exit_price.toFixed(5) }}
                                        </td>
                                        <td
                                            class="px-2 py-1.5 font-mono text-right font-medium"
                                            :class="
                                                trade.pnl_percent >= 0
                                                    ? 'text-emerald-400'
                                                    : 'text-red-400'
                                            "
                                        >
                                            {{ pct(trade.pnl_percent) }}
                                        </td>
                                        <td class="px-2 py-1.5 text-right">
                                            <span
                                                class="text-[10px] px-1.5 py-0.5 rounded"
                                                :class="tradeExitReasonBadgeClass(trade.exit_reason)"
                                                >{{ trade.exit_reason }}</span
                                            >
                                        </td>
                                    </tr>
                                </tbody>
                            </table>
                        </div>
                    </div>
                </template>
            </div>
        </div>
    </main>
</template>

<script setup lang="ts">
import { computed, ref, onMounted, nextTick } from "vue";
import DataTableScaffold from "@/components/ui/DataTableScaffold.vue";
import FilterSelect from "@/components/ui/FilterSelect.vue";
import FilterToolbar from "@/components/ui/FilterToolbar.vue";
import FilterToolbarDivider from "@/components/ui/FilterToolbarDivider.vue";
import SegmentedFilterGroup from "@/components/ui/SegmentedFilterGroup.vue";
import StatusBadge from "@/components/ui/StatusBadge.vue";
import StateMessage from "@/components/ui/StateMessage.vue";
import ViewHeader from "@/components/ui/ViewHeader.vue";
import {
    api,
    opusApi,
    getApiErrorMessage,
    getApiErrorStatus,
} from "@/services/api";
import { tradeExitReasonBadgeClass } from "@/lib/domain-ui";
import { defaultDeployUnits } from "@/lib/market";
import { buildPipelineStageViewModels } from "@/lib/pipeline-stage";
import {
    ariaSortForColumn,
    formatTableNumber,
    formatTablePercent,
    stickyFirstColumnClass,
    tableCellAlignClass,
    tableHeaderAlignClass,
    tableWidthClass,
} from "@/lib/ui";
import { useBacktests } from "@/composables/useBacktests";
import type {
    BacktestRun,
    BacktestTrade,
    BacktestTradesResponse,
} from "@/types/backtest";

const selectedTrades = ref<BacktestTrade[]>([]);
const loadingTrades = ref(false);
const deploying = ref(false);
const deployMessage = ref("");
const deployError = ref(false);
const deployUnits = ref("1000");
const selectedRun = ref<BacktestRun | null>(null);
const chartCanvas = ref<HTMLCanvasElement | null>(null);
const chartWrapper = ref<HTMLDivElement | null>(null);

const {
    results,
    loading,
    running,
    sourceFilter,
    statusFilter,
    instrumentFilter,
    sortKey,
    sortDir,
    strategyFilter,
    granularityFilter,
    runInstrument,
    runTimeframe,
    lastRunResult,
    columns,
    sortedResults,
    toggleSort,
    loadResults: loadResultsCore,
    runGridSearch: runGridSearchCore,
} = useBacktests();

const instruments = [
    "EUR_USD",
    "GBP_USD",
    "USD_JPY",
    "AUD_USD",
    "USD_CAD",
    "XAU_USD",
    "XPT_USD",
    "SPX500_USD",
    "WTICO_USD",
];

const statusFilters = [
    { id: "valid", label: "Valid" },
    { id: "verify", label: "Verify" },
    { id: "failed", label: "Failed" },
];

const strategyFilters = [
    { id: "all", label: "All" },
    { id: "mean_reversion", label: "Mean Reversion" },
    { id: "trend_following", label: "Trend Following" },
];

const granularityFilters = [
    { id: "all", label: "All TF" },
    { id: "M15", label: "M15" },
    { id: "H1", label: "H1" },
    { id: "H4", label: "H4" },
    { id: "D", label: "Daily" },
];

const sourceOptions = [
    { id: "grid", label: "Grid Search" },
    { id: "pipeline", label: "Pipeline" },
];

const instrumentOptions = instruments.map((inst) => ({
    value: inst,
    label: inst.replace("_", "/"),
}));

const pipelineStageRows = computed(() => {
    const evaluations = selectedRun.value?._pipeline?.evaluations ?? [];
    return buildPipelineStageViewModels(evaluations);
});


function cellValue(key: string, row: BacktestRun): string {
    switch (key) {
        case "instrument":
            return row.instrument.replace("_", "/");
        case "granularity":
            return row.granularity ?? "—";
        case "oos_sharpe": {
            const wf = row._pipeline?.evaluations.find(
                (e) => e.stage === "walk_forward",
            );
            const v = wf?.stats?.oos_sharpe;
            return formatTableNumber(v, 3);
        }
        case "strategy_type":
            return row.strategy_type === "mean_reversion"
                ? "Mean Rev"
                : "Trend";
        case "ma_period":
            return String(row.parameters.ma_period ?? "—");
        case "entry_threshold":
            return row.parameters.entry_threshold != null
                ? pct(row.parameters.entry_threshold)
                : "—";
        case "exit_threshold":
            return row.parameters.exit_threshold != null
                ? pct(row.parameters.exit_threshold)
                : "—";
        case "fast_period":
            return String(row.parameters.fast_period ?? "—");
        case "slow_period":
            return String(row.parameters.slow_period ?? "—");
        case "take_profit":
            return row.parameters.take_profit != null
                ? pct(row.parameters.take_profit)
                : "Ride";
        case "stop_loss":
            return pct(row.parameters.stop_loss);
        case "num_trades":
            return String(row.num_trades);
        case "total_return":
            return pct(row.total_return);
        case "win_rate":
            return pct(row.win_rate);
        case "sharpe_ratio":
            return formatTableNumber(row.sharpe_ratio, 2);
        case "max_drawdown":
            return pct(row.max_drawdown);
        case "status":
            return row.status;
        default:
            return "—";
    }
}

function headerClass(key: string, columnIndex: number): string {
    return [
        tableWidthClass("backtests", key),
        tableHeaderAlignClass(key),
        stickyFirstColumnClass({
            isFirst: columnIndex === 0,
            isHeader: true,
        }),
    ]
        .filter(Boolean)
        .join(" ");
}

function cellClass(key: string, row: BacktestRun, columnIndex: number): string {
    const valueClass = (() => {
        switch (key) {
        case "total_return":
            return row.total_return >= 0
                ? "text-emerald-400"
                : "text-red-400";
        case "max_drawdown":
            return "text-red-400";
        case "win_rate":
        case "sharpe_ratio":
        case "num_trades":
            return "text-foreground";
        case "status":
            return "";
        default:
            return "font-mono text-muted-foreground";
        }
    })();

    return [
        tableWidthClass("backtests", key),
        tableCellAlignClass(key),
        valueClass,
        stickyFirstColumnClass({
            isFirst: columnIndex === 0,
            isHeader: false,
            selected: selectedRun.value?.id === row.id,
        }),
    ]
        .filter(Boolean)
        .join(" ");
}

function pct(value: number | null | undefined): string {
    return formatTablePercent(value);
}

async function loadResults() {
    selectedRun.value = null;
    selectedTrades.value = [];
    await loadResultsCore();
}

async function runGridSearch() {
    selectedRun.value = null;
    selectedTrades.value = [];
    await runGridSearchCore();
}

function formatDate(dateStr: string): string {
    const d = new Date(dateStr);
    return (
        d.toLocaleDateString("en-CA", {
            year: "numeric",
            month: "short",
            day: "numeric",
        }) +
        " " +
        d.toLocaleTimeString("en-CA", { hour: "2-digit", minute: "2-digit" })
    );
}

async function selectRun(run: BacktestRun) {
    selectedRun.value = run;
    selectedTrades.value = [];
    deployMessage.value = "";
    deployError.value = false;
    deployUnits.value = defaultDeployUnits(run.instrument);

    if (run._pipeline) return;

    loadingTrades.value = true;
    try {
        const data = await api.get<BacktestTradesResponse>(
            `/backtest/runs/${run.id}/trades`,
        );
        selectedTrades.value = data.trades;
        await nextTick();
        setTimeout(() => drawEquityCurve(), 50);
    } catch (e) {
        console.error("Failed to load trades:", e);
    } finally {
        loadingTrades.value = false;
    }
}

async function deployStrategy() {
    if (!selectedRun.value) return;

    deploying.value = true;
    deployMessage.value = "";
    deployError.value = false;

    try {
        await api.post(`/live/deploy/${selectedRun.value.id}`, {
            max_position_size: deployUnits.value,
        });
        deployMessage.value = `Deployed with ${deployUnits.value} units. Head to Strategies to enable it.`;
        deployError.value = false;
    } catch (e) {
        const message = getApiErrorMessage(e, "Deploy failed");
        // Check for 409 conflict (duplicate)
        if (getApiErrorStatus(e) === 409) {
            deployMessage.value =
                "Already deployed — this strategy is already active for this instrument.";
        } else {
            deployMessage.value = message;
        }
        deployError.value = true;
    } finally {
        deploying.value = false;
    }
}

async function promoteStrategy() {
    if (!selectedRun.value) return;

    deploying.value = true;
    deployMessage.value = "";
    deployError.value = false;

    try {
        await opusApi.post(`/pipeline/${selectedRun.value.id}/promote`, {
            max_position_size: deployUnits.value,
        });
        deployMessage.value = `Promoted with ${deployUnits.value} units. Head to Strategies to enable it.`;
        deployError.value = false;
    } catch (e) {
        if (getApiErrorStatus(e) === 409) {
            deployMessage.value =
                "Already promoted — this strategy is already in live_strategies.";
        } else {
            deployMessage.value = getApiErrorMessage(e, "Promote failed");
        }
        deployError.value = true;
    } finally {
        deploying.value = false;
    }
}

function drawEquityCurve() {
    const canvas = chartCanvas.value;
    const wrapper = chartWrapper.value;
    if (!canvas || !wrapper || selectedTrades.value.length === 0) return;

    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const rect = wrapper.getBoundingClientRect();
    const width = rect.width;
    const height = rect.height;

    canvas.width = width * window.devicePixelRatio;
    canvas.height = height * window.devicePixelRatio;
    canvas.style.width = width + "px";
    canvas.style.height = height + "px";
    ctx.scale(window.devicePixelRatio, window.devicePixelRatio);

    // Build cumulative returns
    const points: { x: number; y: number }[] = [{ x: 0, y: 0 }];
    let cumulative = 0;
    for (let i = 0; i < selectedTrades.value.length; i++) {
        cumulative += selectedTrades.value[i].pnl_percent;
        points.push({ x: i + 1, y: cumulative });
    }

    const maxY = Math.max(...points.map((p) => p.y), 0.001);
    const minY = Math.min(...points.map((p) => p.y), -0.001);
    const rangeY = maxY - minY;
    const padding = { top: 10, bottom: 20, left: 10, right: 10 };

    const chartW = width - padding.left - padding.right;
    const chartH = height - padding.top - padding.bottom;

    function toX(i: number): number {
        return padding.left + (i / (points.length - 1)) * chartW;
    }
    function toY(val: number): number {
        return padding.top + (1 - (val - minY) / rangeY) * chartH;
    }

    ctx.clearRect(0, 0, width, height);

    // Zero line
    const zeroY = toY(0);
    ctx.strokeStyle = "rgba(255,255,255,0.06)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(padding.left, zeroY);
    ctx.lineTo(width - padding.right, zeroY);
    ctx.stroke();

    // Fill area
    ctx.beginPath();
    ctx.moveTo(toX(0), zeroY);
    for (const p of points) {
        ctx.lineTo(toX(p.x), toY(p.y));
    }
    ctx.lineTo(toX(points[points.length - 1].x), zeroY);
    ctx.closePath();

    const finalReturn = points[points.length - 1].y;
    ctx.fillStyle =
        finalReturn >= 0
            ? "rgba(34, 197, 94, 0.08)"
            : "rgba(239, 68, 68, 0.08)";
    ctx.fill();

    // Line
    ctx.beginPath();
    ctx.moveTo(toX(points[0].x), toY(points[0].y));
    for (let i = 1; i < points.length; i++) {
        ctx.lineTo(toX(points[i].x), toY(points[i].y));
    }
    ctx.strokeStyle = finalReturn >= 0 ? "#22c55e" : "#ef4444";
    ctx.lineWidth = 1.5;
    ctx.stroke();

    // Dots
    for (let i = 1; i < points.length; i++) {
        const trade = selectedTrades.value[i - 1];
        ctx.beginPath();
        ctx.arc(toX(points[i].x), toY(points[i].y), 3, 0, Math.PI * 2);
        ctx.fillStyle = trade.pnl_percent >= 0 ? "#22c55e" : "#ef4444";
        ctx.fill();
    }

    // Labels
    ctx.font = "10px 'Fira Code', monospace";
    ctx.fillStyle = "rgba(255,255,255,0.3)";
    ctx.textAlign = "left";
    ctx.fillText((minY * 100).toFixed(2) + "%", padding.left, height - 4);
    ctx.textAlign = "right";
    ctx.fillText(
        (maxY * 100).toFixed(2) + "%",
        width - padding.right,
        padding.top + 10,
    );
}

onMounted(() => {
    loadResults();
});
</script>
