<template>
    <main class="p-6 h-[calc(100vh-57px)] flex flex-col">
        <div class="flex items-center justify-between mb-4">
            <h2 class="text-lg font-semibold text-foreground">
                Backtest Results
            </h2>

            <div class="flex items-center gap-2">
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
            </div>
        </div>

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

        <!-- Filters -->
        <div class="flex items-center gap-3 mb-4">
            <div class="flex gap-1">
                <button
                    v-for="s in statusFilters"
                    :key="s.value"
                    class="px-3 py-1.5 text-sm rounded transition-colors"
                    :class="
                        statusFilter === s.value
                            ? 'bg-primary/10 text-primary'
                            : 'text-muted-foreground hover:text-foreground'
                    "
                    @click="
                        statusFilter = s.value;
                        loadResults();
                    "
                >
                    {{ s.label }}
                </button>
            </div>

            <div class="w-px h-4 bg-border" />

            <div class="flex gap-1">
                <button
                    v-for="s in strategyFilters"
                    :key="s.value"
                    class="px-3 py-1.5 text-sm rounded transition-colors"
                    :class="
                        strategyFilter === s.value
                            ? 'bg-primary/10 text-primary'
                            : 'text-muted-foreground hover:text-foreground'
                    "
                    @click="
                        strategyFilter = s.value;
                        loadResults();
                    "
                >
                    {{ s.label }}
                </button>
            </div>

            <div class="w-px h-4 bg-border" />

            <div class="flex gap-1">
                <button
                    v-for="g in granularityFilters"
                    :key="g.value"
                    class="px-3 py-1.5 text-sm rounded transition-colors"
                    :class="
                        granularityFilter === g.value
                            ? 'bg-primary/10 text-primary'
                            : 'text-muted-foreground hover:text-foreground'
                    "
                    @click="
                        granularityFilter = g.value;
                        loadResults();
                    "
                >
                    {{ g.label }}
                </button>
            </div>

            <select
                v-model="instrumentFilter"
                class="bg-background text-foreground text-sm rounded px-2 py-1 border border-border focus:outline-none focus:border-primary/30"
                @change="loadResults()"
            >
                <option value="">All instruments</option>
                <option v-for="inst in instruments" :key="inst" :value="inst">
                    {{ inst.replace("_", "/") }}
                </option>
            </select>
        </div>

        <!-- Main content: table + detail panel -->
        <div class="flex gap-4 flex-1 min-h-0">
            <!-- Results table -->
            <div class="fr-card overflow-hidden w-[55%]">
                <div
                    v-if="loading"
                    class="p-8 text-center text-muted-foreground text-sm"
                >
                    Loading results...
                </div>

                <div
                    v-else-if="results.length === 0"
                    class="p-8 text-center text-muted-foreground text-sm"
                >
                    No results found.
                </div>

                <div v-else class="overflow-auto h-full">
                    <table class="w-full text-sm">
                        <thead class="sticky top-0 bg-card z-10">
                            <tr class="border-b border-border">
                                <th
                                    v-for="col in columns"
                                    :key="col.key"
                                    class="text-left px-3 py-2.5 text-[10px] font-medium uppercase tracking-wider text-muted-foreground cursor-pointer hover:text-foreground transition-colors whitespace-nowrap"
                                    @click="toggleSort(col.key)"
                                >
                                    {{ col.label }}
                                    <span
                                        v-if="sortKey === col.key"
                                        class="ml-0.5"
                                        >{{
                                            sortDir === "asc" ? "↑" : "↓"
                                        }}</span
                                    >
                                </th>
                            </tr>
                        </thead>
                        <tbody>
                            <tr
                                v-for="row in sortedResults"
                                :key="row.id"
                                class="border-b border-border transition-colors cursor-pointer"
                                :class="
                                    selectedRun?.id === row.id
                                        ? 'bg-primary/[0.05]'
                                        : 'hover:bg-primary/[0.02]'
                                "
                                @click="selectRun(row)"
                            >
                                <td
                                    v-for="col in columns"
                                    :key="col.key"
                                    class="px-3 py-2 whitespace-nowrap"
                                    :class="cellClass(col.key, row)"
                                >
                                    <span
                                        v-if="col.key === 'status'"
                                        class="text-[10px] px-1.5 py-0.5 rounded font-medium"
                                        :class="statusClass(row.status)"
                                        >{{ row.status }}</span
                                    >
                                    <template v-else>{{
                                        cellValue(col.key, row)
                                    }}</template>
                                </td>
                            </tr>
                        </tbody>
                    </table>
                </div>
            </div>

            <!-- Detail panel — always visible -->
            <div class="w-[45%] flex flex-col gap-4 overflow-y-auto">
                <!-- Empty state -->
                <div
                    v-if="!selectedRun"
                    class="fr-card p-8 text-center text-muted-foreground text-sm flex-1 flex items-center justify-center"
                >
                    Select a backtest run to view details
                </div>

                <template v-else>
                    <!-- Stats -->
                    <div class="fr-card p-4">
                        <div class="flex items-center justify-between mb-3">
                            <div class="fr-section-label mb-0 pb-0 border-b-0">
                                {{ selectedRun.strategy_name }}
                            </div>
                            <div class="flex items-center gap-2">
                                <template v-if="selectedRun.status === 'valid'">
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
                                        @click="deployStrategy"
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
                                                ? "Deploying..."
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

                    <!-- Equity curve -->
                    <div class="fr-card p-4">
                        <div class="fr-section-label mb-3">Equity Curve</div>
                        <div
                            v-if="loadingTrades"
                            class="text-sm text-muted-foreground py-4 text-center"
                        >
                            Loading trades...
                        </div>
                        <div
                            v-else-if="selectedTrades.length === 0"
                            class="text-sm text-muted-foreground py-4 text-center"
                        >
                            No trade data
                        </div>
                        <div
                            v-else
                            ref="chartWrapper"
                            class="w-full"
                            style="height: 200px"
                        >
                            <canvas ref="chartCanvas" class="w-full h-full" />
                        </div>
                    </div>

                    <!-- Trade list -->
                    <div class="fr-card p-4">
                        <div class="fr-section-label mb-3">Trades</div>
                        <div
                            v-if="selectedTrades.length === 0"
                            class="text-sm text-muted-foreground py-4 text-center"
                        >
                            No trades
                        </div>
                        <div v-else class="overflow-auto max-h-[300px]">
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
                                                :class="
                                                    trade.exit_reason ===
                                                    'TakeProfit'
                                                        ? 'bg-emerald-500/10 text-emerald-400'
                                                        : trade.exit_reason ===
                                                            'StopLoss'
                                                          ? 'bg-red-500/10 text-red-400'
                                                          : 'bg-muted text-muted-foreground'
                                                "
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
import { ref, computed, onMounted, watch, nextTick } from "vue";
import { api } from "@/services/api";

interface BacktestRun {
    id: string;
    strategy_name: string;
    strategy_type: string;
    instrument: string;
    granularity: string;
    parameters: {
        ma_period: number;
        entry_threshold: number;
        exit_threshold: number;
        stop_loss: number;
        fast_period: number;
        slow_period: number;
        take_profit: number | null;
    };
    total_return: number;
    win_rate: number;
    sharpe_ratio: number;
    max_drawdown: number;
    num_trades: number;
    avg_win: number;
    avg_loss: number;
    status: string;
    reason_flagged: string | null;
    execution_duration_ms: number;
}

interface BacktestTrade {
    id: string;
    entry_price: number;
    exit_price: number;
    entry_time: string;
    exit_time: string;
    pnl_percent: number;
    entry_reason: string;
    exit_reason: string;
}

const results = ref<BacktestRun[]>([]);
const selectedTrades = ref<BacktestTrade[]>([]);
const loading = ref(true);
const loadingTrades = ref(false);
const running = ref(false);
const deploying = ref(false);
const deployMessage = ref("");
const deployError = ref(false);
const deployUnits = ref("1000");
const selectedRun = ref<BacktestRun | null>(null);
const lastRunResult = ref<any>(null);
const chartCanvas = ref<HTMLCanvasElement | null>(null);
const chartWrapper = ref<HTMLDivElement | null>(null);

const statusFilter = ref("valid");
const instrumentFilter = ref("");
const sortKey = ref("sharpe_ratio");
const sortDir = ref<"asc" | "desc">("desc");
const strategyFilter = ref("all");
const granularityFilter = ref("all");

const runInstrument = ref("EUR_USD");
const runTimeframe = ref("H1");

// Sensible default position sizes by instrument type
function defaultUnits(instrument: string): string {
    if (instrument.startsWith("XAU_")) return "1";
    if (instrument.startsWith("XAG_")) return "10";
    if (instrument.startsWith("XPT_") || instrument.startsWith("XPD_"))
        return "1";
    if (instrument.startsWith("XCU_")) return "100";
    // Oil / commodities
    if (["BCO_USD", "WTICO_USD"].includes(instrument)) return "10";
    if (
        [
            "NATGAS_USD",
            "CORN_USD",
            "SOYBN_USD",
            "SUGAR_USD",
            "WHEAT_USD",
        ].includes(instrument)
    )
        return "100";
    // Indices
    if (
        [
            "SPX500_USD",
            "NAS100_USD",
            "US30_USD",
            "JP225_USD",
            "DE30_EUR",
            "UK100_GBP",
            "EU50_EUR",
            "AU200_AUD",
        ].includes(instrument)
    )
        return "1";
    // Bonds
    if (
        instrument.startsWith("USB") ||
        instrument.startsWith("UK10") ||
        instrument.startsWith("DE10")
    )
        return "1";
    // Forex — default
    return "1000";
}

const instruments = [
    "EUR_USD",
    "GBP_USD",
    "USD_JPY",
    "AUD_USD",
    "USD_CAD",
    "XAU_USD",
    "SPX500_USD",
    "WTICO_USD",
];

const statusFilters = [
    { value: "valid", label: "Valid" },
    { value: "verify", label: "Verify" },
    { value: "failed", label: "Failed" },
];

const strategyFilters = [
    { value: "all", label: "All" },
    { value: "mean_reversion", label: "Mean Reversion" },
    { value: "trend_following", label: "Trend Following" },
];

const granularityFilters = [
    { value: "all", label: "All TF" },
    { value: "M15", label: "M15" },
    { value: "H1", label: "H1" },
    { value: "H4", label: "H4" },
    { value: "D", label: "Daily" },
];

const columns = computed(() => {
    if (strategyFilter.value === "trend_following") {
        return [
            { key: "instrument", label: "Pair" },
            { key: "fast_period", label: "Fast" },
            { key: "slow_period", label: "Slow" },
            { key: "stop_loss", label: "Stop" },
            { key: "take_profit", label: "TP" },
            { key: "num_trades", label: "#" },
            { key: "total_return", label: "Return" },
            { key: "win_rate", label: "Win%" },
            { key: "sharpe_ratio", label: "Sharpe" },
            { key: "max_drawdown", label: "DD" },
            { key: "status", label: "Status" },
        ];
    }
    if (strategyFilter.value === "mean_reversion") {
        return [
            { key: "instrument", label: "Pair" },
            { key: "ma_period", label: "MA" },
            { key: "entry_threshold", label: "Entry" },
            { key: "exit_threshold", label: "Exit" },
            { key: "stop_loss", label: "Stop" },
            { key: "num_trades", label: "#" },
            { key: "total_return", label: "Return" },
            { key: "win_rate", label: "Win%" },
            { key: "sharpe_ratio", label: "Sharpe" },
            { key: "max_drawdown", label: "DD" },
            { key: "status", label: "Status" },
        ];
    }
    // All strategies — show generic columns
    return [
        { key: "instrument", label: "Pair" },
        { key: "strategy_type", label: "Strategy" },
        { key: "num_trades", label: "#" },
        { key: "total_return", label: "Return" },
        { key: "win_rate", label: "Win%" },
        { key: "sharpe_ratio", label: "Sharpe" },
        { key: "max_drawdown", label: "DD" },
        { key: "status", label: "Status" },
    ];
});

const sortedResults = computed(() => {
    const sorted = [...results.value];
    sorted.sort((a, b) => {
        let aVal: any, bVal: any;

        const paramKeys = [
            "ma_period",
            "entry_threshold",
            "exit_threshold",
            "stop_loss",
            "fast_period",
            "slow_period",
            "take_profit",
        ];

        if (paramKeys.includes(sortKey.value)) {
            aVal =
                a.parameters[sortKey.value as keyof typeof a.parameters] ?? 0;
            bVal =
                b.parameters[sortKey.value as keyof typeof b.parameters] ?? 0;
        } else {
            aVal = (a as any)[sortKey.value];
            bVal = (b as any)[sortKey.value];
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

function cellValue(key: string, row: BacktestRun): string {
    switch (key) {
        case "instrument":
            return row.instrument.replace("_", "/");
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
            return row.sharpe_ratio.toFixed(2);
        case "max_drawdown":
            return pct(row.max_drawdown);
        case "status":
            return row.status;
        default:
            return "—";
    }
}

function cellClass(key: string, row: BacktestRun): string {
    switch (key) {
        case "total_return":
            return row.total_return >= 0
                ? "font-mono text-emerald-400"
                : "font-mono text-red-400";
        case "max_drawdown":
            return "font-mono text-red-400";
        case "win_rate":
        case "sharpe_ratio":
        case "num_trades":
            return "font-mono text-foreground";
        case "status":
            return "";
        default:
            return "font-mono text-muted-foreground";
    }
}

function toggleSort(key: string) {
    if (sortKey.value === key) {
        sortDir.value = sortDir.value === "asc" ? "desc" : "asc";
    } else {
        sortKey.value = key;
        sortDir.value = "desc";
    }
}

function pct(value: number): string {
    return (value * 100).toFixed(2) + "%";
}

function statusClass(status: string): string {
    switch (status) {
        case "valid":
            return "bg-emerald-500/10 text-emerald-400";
        case "verify":
            return "bg-primary/10 text-primary";
        case "failed":
            return "bg-red-500/10 text-red-400";
        default:
            return "bg-muted text-muted-foreground";
    }
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
    loadingTrades.value = true;
    selectedTrades.value = [];
    deployMessage.value = "";
    deployError.value = false;
    deployUnits.value = defaultUnits(run.instrument);

    try {
        const data = await api.get<{ trades: BacktestTrade[] }>(
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
    } catch (e: any) {
        const message =
            e?.response?.data?.error || e?.message || "Deploy failed";
        // Check for 409 conflict (duplicate)
        if (e?.response?.status === 409) {
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

async function loadResults() {
    loading.value = true;
    try {
        const stratParam =
            strategyFilter.value !== "all"
                ? `&strategy_type=${strategyFilter.value}`
                : "";
        const granParam =
            granularityFilter.value !== "all"
                ? `&granularity=${granularityFilter.value}`
                : "";
        const instParam = instrumentFilter.value
            ? `&instrument=${instrumentFilter.value}`
            : "";

        const data = await api.get<{ results: BacktestRun[] }>(
            `/backtest/results?status=${statusFilter.value}&limit=500${stratParam}${granParam}${instParam}`,
        );
        let filtered = data.results;

        if (instrumentFilter.value) {
            filtered = filtered.filter(
                (r) => r.instrument === instrumentFilter.value,
            );
        }

        results.value = filtered;
    } catch (e) {
        console.error("Failed to load backtest results:", e);
    } finally {
        loading.value = false;
    }
}

async function runGridSearch() {
    running.value = true;
    lastRunResult.value = null;
    try {
        const data = await api.post<any>(
            `/backtest/run?instrument=${runInstrument.value}&timeframe=${runTimeframe.value}`,
            {},
        );
        lastRunResult.value = { ...data, timeframe: runTimeframe.value };
        await loadResults();
    } catch (e) {
        console.error("Grid search failed:", e);
    } finally {
        running.value = false;
    }
}

onMounted(() => {
    loadResults();
});
</script>
