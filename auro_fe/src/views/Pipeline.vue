<template>
    <main class="p-6 h-[calc(100vh-57px)] flex flex-col">
        <div class="flex items-center justify-between mb-4">
            <h2 class="text-lg font-semibold text-foreground">Pipeline</h2>
            <div class="flex items-center gap-2">
                <select
                    v-model="filterStrategy"
                    class="bg-background text-foreground text-sm rounded px-2 py-1 border border-border focus:outline-none focus:border-primary/30"
                >
                    <option value="">All strategies</option>
                    <option value="trend_following">Trend Following</option>
                    <option value="mean_reversion">Mean Reversion</option>
                </select>
                <select
                    v-model="filterGranularity"
                    class="bg-background text-foreground text-sm rounded px-2 py-1 border border-border focus:outline-none focus:border-primary/30"
                >
                    <option value="">All granularities</option>
                    <option value="H1">H1</option>
                    <option value="H4">H4</option>
                    <option value="M15">M15</option>
                </select>
                <select
                    v-model="filterStatus"
                    class="bg-background text-foreground text-sm rounded px-2 py-1 border border-border focus:outline-none focus:border-primary/30"
                >
                    <option value="">All statuses</option>
                    <option value="pending">Pending</option>
                    <option value="running">Running</option>
                    <option value="passed">Passed</option>
                    <option value="failed">Failed</option>
                </select>
                <button
                    @click="load"
                    class="px-3 py-1.5 text-sm rounded bg-primary/10 text-primary hover:bg-primary/20 transition-colors"
                >
                    Refresh
                </button>
            </div>
        </div>

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
        <div class="fr-card flex-1 overflow-hidden flex flex-col">
            <div v-if="loading" class="flex-1 flex items-center justify-center text-muted-foreground text-sm">
                Loading...
            </div>
            <div v-else-if="filtered.length === 0" class="flex-1 flex items-center justify-center text-muted-foreground text-sm">
                No configs found.
            </div>
            <div v-else class="overflow-auto flex-1">
                <table class="w-full text-sm">
                    <thead class="sticky top-0 bg-card border-b border-border">
                        <tr class="text-left text-muted-foreground">
                            <th class="px-3 py-2 font-medium">Instrument</th>
                            <th class="px-3 py-2 font-medium">Strategy</th>
                            <th class="px-3 py-2 font-medium">Gran</th>
                            <th class="px-3 py-2 font-medium">Depth</th>
                            <th class="px-3 py-2 font-medium">Stage</th>
                            <th class="px-3 py-2 font-medium">Status</th>
                            <th class="px-3 py-2 font-medium">Sharpe</th>
                            <th class="px-3 py-2 font-medium">Trades</th>
                            <th class="px-3 py-2 font-medium">Drawdown</th>
                            <th class="px-3 py-2 font-medium">Failure</th>
                        </tr>
                    </thead>
                    <tbody>
                        <tr
                            v-for="c in filtered"
                            :key="c.config_id"
                            class="border-b border-border/40 hover:bg-muted/20 transition-colors"
                        >
                            <td class="px-3 py-2 font-mono text-foreground">
                                {{ c.instrument.replace("_", "/") }}
                            </td>
                            <td class="px-3 py-2 text-muted-foreground">
                                {{ strategyLabel(c.strategy_type) }}
                            </td>
                            <td class="px-3 py-2 font-mono text-xs text-muted-foreground">
                                {{ c.granularity }}
                            </td>
                            <td class="px-3 py-2">
                                <span
                                    class="px-1.5 py-0.5 rounded text-xs font-mono"
                                    :class="c.depth > 0 ? 'bg-primary/10 text-primary' : 'bg-muted text-muted-foreground'"
                                >
                                    {{ c.depth }}
                                </span>
                            </td>
                            <td class="px-3 py-2 text-muted-foreground font-mono text-xs">
                                {{ stageLabel(c.stage) }}
                            </td>
                            <td class="px-3 py-2">
                                <span
                                    class="px-2 py-0.5 rounded-full text-xs font-medium"
                                    :class="statusClass(c.status)"
                                >
                                    {{ c.status || "pending" }}
                                </span>
                            </td>
                            <td class="px-3 py-2 font-mono text-xs" :class="sharpeColor(sharpeStat(c))">
                                {{ fmt(sharpeStat(c)) }}
                            </td>
                            <td class="px-3 py-2 font-mono text-xs text-muted-foreground">
                                {{ tradesStat(c) ?? "—" }}
                            </td>
                            <td class="px-3 py-2 font-mono text-xs text-red-400">
                                {{ drawdownStat(c) != null ? (drawdownStat(c)! * 100).toFixed(1) + "%" : "—" }}
                            </td>
                            <td class="px-3 py-2 text-xs text-muted-foreground max-w-[200px] truncate" :title="c.failure_reason ?? undefined">
                                {{ c.failure_reason || "—" }}
                            </td>
                        </tr>
                    </tbody>
                </table>
            </div>
        </div>
    </main>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from "vue";

const OPUS_BASE = "http://localhost:4321";

interface Evaluation {
    stage: string;
    status: string;
    stats: Record<string, number> | null;
    failure_reason: string | null;
}

interface Config {
    config_id: string;
    instrument: string;
    granularity: string;
    strategy_type: string;
    source: string;
    depth: number;
    parent_config_id: string | null;
    stage: string | null;
    status: string | null;
    stats: Record<string, number> | null;
    failure_reason: string | null;
    evaluations: Evaluation[];
}

interface Summary {
    total: number;
    running: number;
    passed: number;
    failed: number;
    pending: number;
    backtest: number;
    walk_forward: number;
    monte_carlo: number;
}

const loading = ref(false);
const configs = ref<Config[]>([]);
const summary = ref<Summary | null>(null);
const filterStrategy = ref("");
const filterGranularity = ref("");
const filterStatus = ref("");

const filtered = computed(() => {
    return configs.value.filter((c) => {
        if (filterStrategy.value && c.strategy_type !== filterStrategy.value) return false;
        if (filterGranularity.value && c.granularity !== filterGranularity.value) return false;
        if (filterStatus.value && (c.status || "pending") !== filterStatus.value) return false;
        return true;
    });
});

async function load() {
    loading.value = true;
    try {
        const res = await fetch(`${OPUS_BASE}/api/pipeline`);
        const data = await res.json();
        configs.value = data.configs ?? [];
        summary.value = data.summary ?? null;
    } catch (e) {
        console.error("Failed to load pipeline status", e);
    } finally {
        loading.value = false;
    }
}

function strategyLabel(type: string) {
    return type === "trend_following" ? "Trend" : type === "mean_reversion" ? "Mean Rev" : type;
}

function stageLabel(stage: string | null) {
    if (!stage) return "—";
    return { backtest: "Backtest", walk_forward: "Walk-fwd", monte_carlo: "Monte Carlo" }[stage] ?? stage;
}

function statusClass(status: string | null) {
    switch (status) {
        case "passed": return "bg-emerald-500/15 text-emerald-400";
        case "failed": return "bg-red-500/15 text-red-400";
        case "running": return "bg-yellow-500/15 text-yellow-400";
        default: return "bg-muted text-muted-foreground";
    }
}

function sharpeStat(c: Config): number | null {
    if (!c.stats) return null;
    return c.stats.sharpe ?? c.stats.oos_sharpe ?? c.stats.median_sharpe ?? null;
}

function tradesStat(c: Config): number | null {
    if (!c.stats) return null;
    return c.stats.num_trades ?? c.stats.oos_num_trades ?? null;
}

function drawdownStat(c: Config): number | null {
    if (!c.stats) return null;
    return c.stats.max_drawdown ?? c.stats.p95_drawdown ?? null;
}

function sharpeColor(v: number | null) {
    if (v === null) return "text-muted-foreground";
    if (v >= 2.0) return "text-emerald-400";
    if (v >= 1.0) return "text-primary";
    return "text-red-400";
}

function fmt(v: number | null) {
    return v !== null ? v.toFixed(2) : "—";
}

onMounted(load);
</script>
