<template>
    <main class="p-6">
        <ViewHeader title="Dashboard" />

        <SystemPulseStrip />

        <div class="mb-4">
            <EquityCurvePanel />
        </div>

        <div class="mb-4">
            <PerformanceKpisPanel />
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
            <!-- Open Positions -->
            <div class="lg:col-span-3">
                <OpenPositionsPanel />
            </div>

            <!-- Signal Feed -->
            <div class="lg:col-span-3">
                <SignalFeedPanel />
            </div>

            <!-- Regime Heatmap -->
            <div class="lg:col-span-3">
                <RegimeHeatmapPanel />
            </div>

            <!-- Algo Activity -->
            <div class="lg:col-span-2 min-h-0">
                <DataCard
                    :loading="algoLoading"
                    :empty="algoActivity.length === 0"
                    loading-message="Loading activity..."
                    empty-message="No algo activity yet — waiting for signals"
                    card-class="p-4 h-full"
                    content-class=""
                >
                    <div class="flex items-center justify-between mb-4">
                        <div class="fr-section-label mb-0 pb-0 border-b-0">
                            Algo Activity
                        </div>
                        <span class="text-[10px] text-muted-foreground font-mono">
                            Last {{ algoActivity.length }} trades
                        </span>
                    </div>

                    <div class="space-y-2">
                    <router-link
                        v-for="entry in algoActivity"
                        :key="entry.id"
                        :to="`/live-trades/${entry.id}`"
                        class="block bg-background rounded-md p-3 hover:bg-muted/40 transition-colors cursor-pointer"
                    >
                        <!-- Top row: action badge, instrument, strategy, units, time -->
                        <div class="flex items-center justify-between mb-2">
                            <div class="flex items-center gap-2 flex-wrap">
                                <BadgePill
                                    :label="entry.action"
                                    :extra-class="actionColor(entry.action)"
                                />
                                <span class="text-sm text-foreground">
                                    {{ entry.instrument.replace("_", "/") }}
                                </span>
                                <span
                                    v-if="entry.strategyLabel"
                                    class="text-[10px] font-mono px-1.5 py-0.5 rounded bg-primary/8 text-primary/70"
                                >
                                    {{ entry.strategyLabel }}
                                </span>
                                <span
                                    class="font-mono text-xs text-muted-foreground"
                                >
                                    {{ entry.units }} units
                                </span>
                            </div>
                            <span
                                class="text-[10px] text-muted-foreground font-mono"
                            >
                                {{ entry.time }}
                            </span>
                        </div>

                        <!-- Price + PnL + duration row -->
                        <div
                            class="flex items-center gap-2 mb-1.5 font-mono text-sm"
                        >
                            <span class="text-foreground">
                                ${{
                                    formatPrice(
                                        entry.entryPrice,
                                        entry.instrument,
                                    )
                                }}
                            </span>
                            <template v-if="entry.exitPrice != null">
                                <span class="text-muted-foreground">→</span>
                                <span class="text-foreground">
                                    ${{
                                        formatPrice(
                                            entry.exitPrice,
                                            entry.instrument,
                                        )
                                    }}
                                </span>
                            </template>
                            <span
                                v-if="entry.pnl != null"
                                class="text-xs font-medium"
                                :class="
                                    entry.pnl >= 0
                                        ? 'text-emerald-400'
                                        : 'text-red-400'
                                "
                            >
                                {{ entry.pnl >= 0 ? "+" : ""
                                }}{{ (entry.pnl * 100).toFixed(2) }}%
                            </span>
                            <span
                                v-if="entry.duration"
                                class="text-[10px] text-muted-foreground ml-auto"
                            >
                                {{ entry.duration }}
                            </span>
                        </div>

                        <!-- Reason row: entry reason → exit reason -->
                        <div
                            v-if="entry.entryReason || entry.exitReason"
                            class="flex items-center gap-1.5 text-xs"
                        >
                            <span
                                v-if="entry.entryReason"
                                class="text-muted-foreground"
                                :title="entry.entryReason"
                            >
                                {{ reasonShort(entry.entryReason) }}
                            </span>
                            <template v-if="entry.exitReason">
                                <span
                                    v-if="entry.entryReason"
                                    class="text-muted-foreground"
                                    >→</span
                                >
                                <span
                                    class="font-medium"
                                    :class="
                                        exitReasonColor(entry.exitReason)
                                    "
                                    :title="entry.exitReason"
                                >
                                    {{ reasonShort(entry.exitReason) }}
                                </span>
                            </template>
                        </div>
                    </router-link>
                    </div>
                </DataCard>
            </div>

            <!-- Market News -->
            <div class="lg:col-span-3 fr-card p-4">
                <div class="fr-section-label mb-4">Market News</div>

                <div class="text-sm text-muted-foreground py-8 text-center">
                    Coming soon — news feed integration
                </div>
            </div>
        </div>
    </main>
</template>

<script setup lang="ts">
import { useDashboard } from "@/composables/useDashboard";
import BadgePill from "@/components/ui/BadgePill.vue";
import DataCard from "@/components/ui/DataCard.vue";
import EquityCurvePanel from "@/components/dashboard/EquityCurvePanel.vue";
import OpenPositionsPanel from "@/components/dashboard/OpenPositionsPanel.vue";
import PerformanceKpisPanel from "@/components/dashboard/PerformanceKpisPanel.vue";
import RegimeHeatmapPanel from "@/components/dashboard/RegimeHeatmapPanel.vue";
import SignalFeedPanel from "@/components/dashboard/SignalFeedPanel.vue";
import SystemPulseStrip from "@/components/dashboard/SystemPulseStrip.vue";
import ViewHeader from "@/components/ui/ViewHeader.vue";

const {
    algoActivity,
    algoLoading,
    actionColor,
    formatPrice,
    reasonShort,
    exitReasonColor,
} = useDashboard();
</script>