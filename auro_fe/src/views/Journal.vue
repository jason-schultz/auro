<template>
    <main class="p-6 h-[calc(100vh-57px)] flex flex-col">
        <ViewHeader title="Trade Journal" :compact="true">
            <template #actions>
                <span class="text-xs text-muted-foreground font-mono">
                    {{ closedCount }} closed · {{ openCount }} open
                </span>
            </template>
        </ViewHeader>

        <section
            v-if="!introDismissed"
            class="mb-4 rounded-md border border-border bg-background/60 p-3"
        >
            <div class="flex items-center justify-between gap-2">
                <h3 class="text-sm font-semibold text-foreground">How to read this page</h3>
                <div class="flex items-center gap-2">
                    <button
                        type="button"
                        class="text-xs text-muted-foreground hover:text-foreground"
                        @click="introOpen = !introOpen"
                    >
                        {{ introOpen ? "Collapse" : "Expand" }}
                    </button>
                    <button
                        type="button"
                        class="text-xs text-muted-foreground hover:text-foreground"
                        @click="dismissIntro"
                    >
                        Dismiss
                    </button>
                </div>
            </div>
            <p v-if="introOpen" class="mt-2 text-xs leading-5 text-muted-foreground">
                This page is your closed-trade scoreboard: if total realized P&L trends up with healthy average wins relative to average losses, your strategy has edge; if P&L is flat/down, MAE stays large, or MFE is much bigger than what you actually banked, you are likely cutting winners too early, setting stops poorly, or trading the wrong market regime.
            </p>
        </section>

        <FilterToolbar>
            <SegmentedFilterGroup
                v-model="statusFilter"
                :options="statusOptions"
                active-class="bg-primary/10 text-primary"
                inactive-class="text-muted-foreground hover:text-foreground"
            />
            <FilterToolbarDivider />
            <SegmentedFilterGroup
                v-model="strategyFilter"
                :options="strategyOptions"
                active-class="bg-primary/10 text-primary"
                inactive-class="text-muted-foreground hover:text-foreground"
            />
            <FilterToolbarDivider />
            <SegmentedFilterGroup
                v-model="granularityFilter"
                :options="granularityOptions"
                active-class="bg-primary/10 text-primary"
                inactive-class="text-muted-foreground hover:text-foreground"
            />
        </FilterToolbar>

        <DataTableScaffold
            :loading="loading"
            :empty="filteredTrades.length === 0"
            empty-message="No trades match this filter."
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
                    :aria-sort="getAriaSortForColumn(col)"
                    @click="col.sortable && setSortKey(col.key)"
                >
                    <button
                        v-if="col.sortable"
                        type="button"
                        class="inline-flex items-center gap-0.5 transition-colors"
                    >
                        <MetricLabel
                            :label="col.label"
                            :explainer="journalMetricExplainers[col.key]"
                        />
                        <span class="text-[9px] ml-0.5 opacity-50">
                            {{ sortKey === col.key ? (sortDir === "asc" ? "▲" : "▼") : "⇅" }}
                        </span>
                    </button>
                    <MetricLabel
                        v-else
                        :label="col.label"
                        :explainer="journalMetricExplainers[col.key]"
                    />
                </th>
            </template>

            <template #body>
                <template v-for="trade in paginatedTrades" :key="trade.id">
                    <tr
                        class="border-b border-border/50 hover:bg-muted/30 transition-colors cursor-pointer"
                        :class="{ 'bg-muted/10': expandedId === trade.id }"
                        @click="toggleExpand(trade.id)"
                    >
                        <td class="px-3 py-2 font-mono text-xs whitespace-nowrap">
                            <div class="font-medium">{{ trade.instrument }}</div>
                            <div class="text-muted-foreground text-[10px]">{{ trade.strategy_granularity }}</div>
                        </td>
                        <td class="px-3 py-2 whitespace-nowrap">
                            <span
                                class="text-[10px] font-medium px-1.5 py-0.5 rounded"
                                :class="trade.strategy_type === 'trend_following'
                                    ? 'bg-violet-500/15 text-violet-400'
                                    : 'bg-blue-500/15 text-blue-400'"
                            >{{ strategyTypeLabel(trade.strategy_type ?? '') }}</span>
                        </td>
                        <td class="px-3 py-2 whitespace-nowrap">
                            <span
                                class="text-[10px] font-semibold"
                                :class="trade.direction === 'Long' ? 'text-green-400' : 'text-red-400'"
                            >{{ trade.direction }}</span>
                        </td>
                        <td class="px-3 py-2 font-mono text-xs text-right whitespace-nowrap">
                            <div>{{ trade.entry_price?.toFixed(5) ?? '—' }}</div>
                            <div class="text-muted-foreground text-[10px]">{{ fmtDatetime(trade.entry_time) }}</div>
                        </td>
                        <td class="px-3 py-2 font-mono text-xs text-right whitespace-nowrap">
                            <template v-if="trade.status === 'open'">
                                <span class="text-yellow-400 text-[10px]">Open</span>
                            </template>
                            <template v-else>
                                <div>{{ trade.exit_price?.toFixed(5) ?? '—' }}</div>
                                <div class="text-muted-foreground text-[10px]">{{ fmtDatetime(trade.exit_time) }}</div>
                            </template>
                        </td>
                        <td class="px-3 py-2 font-mono text-xs text-right whitespace-nowrap">
                            <span :class="pnlClass(trade.pnl_percent)">
                                {{ fmtPct(trade.pnl_percent) }}
                            </span>
                        </td>
                        <td class="px-3 py-2 text-xs text-right whitespace-nowrap text-muted-foreground">
                            {{ fmtDuration(trade) }}
                        </td>
                        <td class="px-3 py-2 font-mono text-xs text-right whitespace-nowrap">
                            <span v-if="trade.mae_pct != null" class="text-red-400">{{ fmtPct(trade.mae_pct) }}</span>
                            <span v-else class="text-muted-foreground">—</span>
                        </td>
                        <td class="px-3 py-2 font-mono text-xs text-right whitespace-nowrap">
                            <span v-if="trade.mfe_pct != null" class="text-green-400">{{ fmtPct(trade.mfe_pct) }}</span>
                            <span v-else class="text-muted-foreground">—</span>
                        </td>
                        <td class="px-3 py-2 text-xs whitespace-nowrap max-w-40 truncate text-muted-foreground" :title="trade.regime_at_entry ?? ''">
                            {{ trade.regime_at_entry ?? '—' }}
                        </td>
                        <td class="px-3 py-2 text-xs whitespace-nowrap text-muted-foreground">
                            {{ trade.exit_reason ?? '—' }}
                        </td>
                        <td class="px-3 py-2 text-xs whitespace-nowrap">
                            <span v-if="trade.stop_loss_state_at_close" :class="slStateClass(trade.stop_loss_state_at_close)">
                                {{ trade.stop_loss_state_at_close }}
                            </span>
                            <span v-else class="text-muted-foreground">—</span>
                        </td>
                    </tr>

                    <!-- Expandable detail row: entry indicators + strategy parameters -->
                    <tr v-if="expandedId === trade.id" :key="trade.id + '-detail'">
                        <td colspan="12" class="px-4 py-3 bg-muted/20 border-b border-border">
                            <div class="mb-4 rounded-md border border-border bg-background/70 p-3">
                                <div class="text-[10px] uppercase tracking-wider text-muted-foreground mb-2">What happened on this trade</div>
                                <p class="text-xs text-muted-foreground leading-5 mb-1">{{ strategyPrimerText(trade) }}</p>
                                <p class="text-xs text-foreground leading-5 mb-1">{{ tradeEntryNarrativeText(trade) }}</p>
                                <p class="text-xs text-foreground leading-5">{{ tradeExitNarrativeText(trade) }}</p>
                            </div>
                            <div class="grid grid-cols-2 gap-6 text-xs">
                                <div>
                                    <div class="text-[10px] uppercase tracking-wider text-muted-foreground mb-2">Entry Indicators</div>
                                    <template v-if="trade.indicators_at_entry">
                                        <div
                                            v-for="(val, key) in trade.indicators_at_entry"
                                            :key="key"
                                            class="flex justify-between font-mono text-[11px] py-0.5 border-b border-border/30"
                                        >
                                            <span class="text-muted-foreground">{{ key }}</span>
                                            <span>{{ formatIndicatorValue(val) }}</span>
                                        </div>
                                    </template>
                                    <span v-else class="text-muted-foreground italic">Not captured (trade pre-dates journal enrichment)</span>
                                </div>
                                <div>
                                    <div class="text-[10px] uppercase tracking-wider text-muted-foreground mb-2">Strategy Parameters</div>
                                    <template v-if="trade.strategy_parameters">
                                        <div
                                            v-for="(val, key) in trade.strategy_parameters"
                                            :key="key"
                                            class="flex justify-between font-mono text-[11px] py-0.5 border-b border-border/30"
                                        >
                                            <span class="text-muted-foreground">{{ key }}</span>
                                            <span>{{ val ?? '—' }}</span>
                                        </div>
                                    </template>
                                    <span v-else class="text-muted-foreground">—</span>
                                </div>
                            </div>
                        </td>
                    </tr>
                </template>
            </template>
        </DataTableScaffold>

        <div v-if="totalPages > 1" class="flex items-center justify-between pt-2 text-xs text-muted-foreground shrink-0">
            <span>{{ filteredTrades.length }} trades</span>
            <div class="flex gap-1">
                <button
                    class="px-2 py-1 rounded border border-border hover:bg-muted disabled:opacity-30"
                    :disabled="page === 1"
                    @click="page--"
                >&lsaquo;</button>
                <span class="px-2 py-1">{{ page }} / {{ totalPages }}</span>
                <button
                    class="px-2 py-1 rounded border border-border hover:bg-muted disabled:opacity-30"
                    :disabled="page === totalPages"
                    @click="page++"
                >&rsaquo;</button>
            </div>
        </div>
    </main>
</template>

<script setup lang="ts">
import { onMounted } from "vue";
import DataTableScaffold from "@/components/ui/DataTableScaffold.vue";
import FilterToolbar from "@/components/ui/FilterToolbar.vue";
import FilterToolbarDivider from "@/components/ui/FilterToolbarDivider.vue";
import MetricLabel from "@/components/ui/MetricLabel.vue";
import SegmentedFilterGroup from "@/components/ui/SegmentedFilterGroup.vue";
import ViewHeader from "@/components/ui/ViewHeader.vue";
import { JOURNAL_METRIC_EXPLAINERS } from "@/lib/metricExplainers";
import { useJournal } from "@/composables/useJournal";
import { ref } from "vue";

const INTRO_DISMISS_KEY = "journal_intro_dismissed_v1";
const introOpen = ref(true);
const introDismissed = ref(false);
const journalMetricExplainers = JOURNAL_METRIC_EXPLAINERS;

function dismissIntro() {
    introDismissed.value = true;
    localStorage.setItem(INTRO_DISMISS_KEY, "true");
}

const {
    loading,
    statusFilter,
    strategyFilter,
    granularityFilter,
    statusOptions,
    strategyOptions,
    granularityOptions,
    sortKey,
    sortDir,
    page,
    totalPages,
    expandedId,
    columns,
    closedCount,
    openCount,
    filteredTrades,
    paginatedTrades,
    load,
    setSortKey,
    toggleExpand,
    headerClass,
    getAriaSortForColumn,
    fmtPct,
    fmtDatetime,
    fmtDuration,
    strategyPrimerText,
    tradeEntryNarrativeText,
    tradeExitNarrativeText,
    pnlClass,
    slStateClass,
    formatIndicatorValue,
    strategyTypeLabel,
} = useJournal();

onMounted(() => {
    introDismissed.value = localStorage.getItem(INTRO_DISMISS_KEY) === "true";
    load();
});
</script>
