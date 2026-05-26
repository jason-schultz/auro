<template>
    <div class="fr-card p-4">
        <div class="flex flex-wrap items-center justify-between gap-3 mb-4">
            <div class="fr-section-label mb-0">Rules State</div>

            <div class="flex items-center gap-2 text-[10px] font-mono">
                <BadgePill
                    :label="`${summary.trading} trading / ${summary.live} live`"
                    extra-class="bg-emerald-500/12 text-emerald-300"
                />
                <BadgePill
                    :label="`curator: ${summary.curator_enabled ? 'on' : 'off'}`"
                    :extra-class="summary.curator_enabled ? 'bg-blue-500/12 text-blue-300' : 'bg-muted text-muted-foreground'"
                />
                <span class="text-muted-foreground">As of {{ asOfLabel }}</span>
            </div>
        </div>

        <StateMessage
            v-if="loading && strategies.length === 0"
            :compact="true"
            message="Loading rules state..."
        />

        <StateMessage
            v-else-if="error"
            :compact="true"
            :message="error"
        />

        <StateMessage
            v-else-if="strategies.length === 0"
            :compact="true"
            message="No live strategies configured"
        />

        <div v-else class="overflow-x-auto">
            <table class="w-full min-w-180 text-sm border-separate border-spacing-y-2">
                <thead>
                    <tr class="text-left text-[10px] uppercase tracking-wider text-muted-foreground">
                        <th class="py-1 pr-2">Instrument</th>
                        <th class="py-1 pr-2">Granularity</th>
                        <th class="py-1 pr-2">Strategy</th>
                        <th class="py-1 pr-2">State</th>
                        <th class="py-1 pr-2">Tactical</th>
                        <th class="py-1 pr-2">Composite</th>
                        <th class="py-1 pr-2">Frames</th>
                        <th class="py-1 pr-2">Reason</th>
                    </tr>
                </thead>
                <tbody>
                    <tr
                        v-for="row in strategies"
                        :key="row.live_strategy_id"
                        class="bg-background"
                    >
                        <td class="py-2 pr-2 whitespace-nowrap font-mono text-xs text-foreground">
                            {{ row.instrument.replace("_", "/") }}
                        </td>
                        <td class="py-2 pr-2 whitespace-nowrap font-mono text-xs text-muted-foreground">
                            {{ row.granularity }}
                        </td>
                        <td class="py-2 pr-2 whitespace-nowrap text-xs text-foreground">
                            {{ strategyLabel(row.strategy_type) }}
                        </td>
                        <td class="py-2 pr-2 whitespace-nowrap">
                            <BadgePill
                                label="live"
                                extra-class="bg-blue-500/12 text-blue-300"
                            />
                        </td>
                        <td class="py-2 pr-2 whitespace-nowrap">
                            <BadgePill
                                :label="row.rules_enabled ? 'trading' : 'gated'"
                                :extra-class="row.rules_enabled ? 'bg-emerald-500/12 text-emerald-300' : 'bg-red-500/12 text-red-300'"
                            />
                        </td>
                        <td class="py-2 pr-2 whitespace-nowrap">
                            <span
                                class="inline-flex items-center px-2 py-1 rounded-md text-[11px] capitalize border"
                                :class="compositeClass(row.composite_regime)"
                            >
                                {{ row.composite_regime ?? "n/a" }}
                            </span>
                        </td>
                        <td class="py-2 pr-2 min-w-56">
                            <div class="flex flex-wrap gap-1.5">
                                <span
                                    v-for="frame in row.frames"
                                    :key="frameBadgeKey(row.live_strategy_id, frame)"
                                    class="inline-flex items-center gap-1 px-2 py-1 rounded-md border text-[10px] font-mono"
                                    :class="frameClass(frame.regime)"
                                    :title="frameTooltip(frame)"
                                >
                                    <span>{{ frame.frame ?? "?" }}</span>
                                    <span class="capitalize">{{ frame.regime ?? "n/a" }}</span>
                                    <span class="opacity-70">{{ formatAdx(frame.adx) }}</span>
                                </span>
                                <span
                                    v-if="row.frames.length === 0"
                                    class="text-xs text-muted-foreground"
                                >
                                    n/a
                                </span>
                            </div>
                        </td>
                        <td class="py-2 pr-2 max-w-80">
                            <span
                                class="text-xs text-muted-foreground truncate block"
                                :title="row.reason"
                            >
                                {{ row.reason }}
                            </span>
                        </td>
                    </tr>
                </tbody>
            </table>
        </div>
    </div>
</template>

<script setup lang="ts">
import { computed } from "vue";
import BadgePill from "@/components/ui/BadgePill.vue";
import StateMessage from "@/components/ui/StateMessage.vue";
import { useRulesState, type RuleFrameInput } from "@/composables/useRulesState";
import { strategyTypeLabel } from "@/lib/strategy";
import { timeAgoCompact } from "@/lib/time";

const {
    loading,
    error,
    computedAt,
    summary,
    strategies,
} = useRulesState();

const asOfLabel = computed(() => {
    if (!computedAt.value) return "never";
    return timeAgoCompact(computedAt.value);
});

function strategyLabel(strategyType: string): string {
    return strategyTypeLabel(strategyType);
}

function formatAdx(adx: number | null): string {
    if (adx == null || Number.isNaN(adx)) return "ADX --";
    return `ADX ${adx.toFixed(1)}`;
}

function frameBadgeKey(strategyId: string, frame: RuleFrameInput): string {
    return `${strategyId}-${frame.frame ?? "na"}-${frame.regime ?? "na"}`;
}

function frameTooltip(frame: RuleFrameInput): string {
    return `${frame.frame ?? "?"}: ${frame.regime ?? "n/a"} (${formatAdx(frame.adx)})`;
}

function compositeClass(regime: string | null): string {
    switch (regime) {
        case "trending":
            return "bg-emerald-500/12 text-emerald-300 border-emerald-500/35";
        case "choppy":
            return "bg-red-500/12 text-red-300 border-red-500/35";
        case "uncertain":
            return "bg-amber-500/12 text-amber-300 border-amber-500/35";
        default:
            return "bg-muted text-muted-foreground border-border";
    }
}

function frameClass(regime: string | null): string {
    return compositeClass(regime);
}
</script>
