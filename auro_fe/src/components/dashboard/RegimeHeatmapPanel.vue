<template>
    <div class="fr-card p-4">
        <div class="flex items-center justify-between mb-4">
            <div class="fr-section-label mb-0">Regime Heatmap</div>
            <button
                type="button"
                class="inline-flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground transition-colors"
                @click="toggleCollapsed"
            >
                <span class="font-mono">{{ isCollapsed ? "▸" : "▾" }}</span>
                <span>{{ isCollapsed ? "Expand" : "Collapse" }}</span>
            </button>
        </div>

        <div v-if="isCollapsed" class="text-xs text-muted-foreground">
            Hidden by default. Expand to inspect frame-level regime and ADX values.
        </div>

        <template v-else>

            <StateMessage
                v-if="loading && rows.length === 0"
                :compact="true"
                message="Loading regime matrix..."
            />

            <StateMessage
                v-else-if="error"
                :compact="true"
                :message="error"
            />

            <StateMessage
                v-else-if="rows.length === 0"
                :compact="true"
                message="No enabled strategies yet"
            />

            <div v-else class="overflow-x-auto">
                <table class="w-full text-sm border-separate border-spacing-y-2 min-w-140">
                    <thead>
                        <tr class="text-left text-[10px] uppercase tracking-wider text-muted-foreground">
                            <th class="py-1 pr-2">Instrument</th>
                            <th
                                v-for="granularity in granularities"
                                :key="granularity"
                                class="py-1 px-2 text-center"
                            >
                                {{ granularity }}
                            </th>
                        </tr>
                    </thead>
                    <tbody>
                        <tr
                            v-for="row in rows"
                            :key="row.instrument"
                        >
                            <td class="py-2 pr-2 font-mono text-foreground whitespace-nowrap">
                                {{ row.instrument.replace("_", "/") }}
                            </td>
                            <td
                                v-for="cell in row.cells"
                                :key="`${row.instrument}-${cell.granularity}`"
                                class="py-2 px-2"
                            >
                                <div
                                    class="rounded-md px-2 py-1.5 text-center border"
                                    :class="regimeCellClass(cell)"
                                    :title="cellTitle(cell)"
                                >
                                    <div class="font-medium capitalize leading-tight">
                                        {{ cell.applicable ? cell.regime : 'n/a' }}
                                    </div>
                                    <div class="text-[10px] font-mono opacity-80 leading-tight mt-0.5">
                                        ADX {{ cell.applicable ? formatAdx(cell.adx) : '--' }}
                                    </div>
                                </div>
                            </td>
                        </tr>
                    </tbody>
                </table>
            </div>
        </template>
    </div>
</template>

<script setup lang="ts">
import { onMounted, ref } from "vue";
import StateMessage from "@/components/ui/StateMessage.vue";
import {
    type RegimeHeatmapCell,
    useRegimeHeatmap,
} from "@/composables/useRegimeHeatmap";

const COLLAPSE_KEY = "regime_heatmap_collapsed";

const {
    loading,
    error,
    rows,
    granularities,
} = useRegimeHeatmap();

const isCollapsed = ref(true);

function toggleCollapsed() {
    isCollapsed.value = !isCollapsed.value;
    localStorage.setItem(COLLAPSE_KEY, isCollapsed.value ? "true" : "false");
}

onMounted(() => {
    const stored = localStorage.getItem(COLLAPSE_KEY);
    if (stored === "true") isCollapsed.value = true;
    if (stored === "false") isCollapsed.value = false;
});

function regimeCellClass(cell: RegimeHeatmapCell): string {
    if (!cell.applicable) {
        return "bg-transparent text-muted-foreground/70 border-dashed border-border";
    }

    const regime = cell.regime;
    switch (regime) {
        case "trending":
            return "bg-emerald-500/12 text-emerald-300 border-emerald-500/35";
        case "choppy":
            return "bg-red-500/12 text-red-300 border-red-500/35";
        case "uncertain":
            return "bg-amber-500/12 text-amber-300 border-amber-500/35";
        default:
            return "bg-muted/50 text-muted-foreground border-border";
    }
}

function formatAdx(adx: number | null): string {
    if (adx == null || Number.isNaN(adx)) return "--";
    return adx.toFixed(1);
}

function cellTitle(cell: RegimeHeatmapCell): string {
    if (!cell.applicable) {
        return "Not used for this instrument's enabled strategy granularities";
    }

    const adx = formatAdx(cell.adx);
    const bw = cell.bandwidth_pct == null ? "--" : cell.bandwidth_pct.toFixed(2);
    const ts = cell.last_close_time ?? "n/a";
    return `Regime: ${cell.regime} | ADX: ${adx} | BW: ${bw}% | Last close: ${ts}`;
}
</script>
