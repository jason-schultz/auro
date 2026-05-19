<template>
    <div class="fr-card p-4">
        <div class="fr-section-label mb-4">Regime Heatmap</div>

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
                                :class="regimeCellClass(cell.regime)"
                                :title="cellTitle(cell)"
                            >
                                <div class="font-medium capitalize leading-tight">
                                    {{ cell.regime }}
                                </div>
                                <div class="text-[10px] font-mono opacity-80 leading-tight mt-0.5">
                                    ADX {{ formatAdx(cell.adx) }}
                                </div>
                            </div>
                        </td>
                    </tr>
                </tbody>
            </table>
        </div>
    </div>
</template>

<script setup lang="ts">
import StateMessage from "@/components/ui/StateMessage.vue";
import {
    type RegimeHeatmapCell,
    type RegimeState,
    useRegimeHeatmap,
} from "@/composables/useRegimeHeatmap";

const {
    loading,
    error,
    rows,
    granularities,
} = useRegimeHeatmap();

function regimeCellClass(regime: RegimeState): string {
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
    const adx = formatAdx(cell.adx);
    const bw = cell.bandwidth_pct == null ? "--" : cell.bandwidth_pct.toFixed(2);
    const ts = cell.last_close_time ?? "n/a";
    return `Regime: ${cell.regime} | ADX: ${adx} | BW: ${bw}% | Last close: ${ts}`;
}
</script>
