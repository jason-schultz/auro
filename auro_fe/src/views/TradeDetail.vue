<template>
    <main class="p-6">
        <div class="flex items-center justify-between mb-4">
            <div class="flex items-center gap-3">
                <router-link
                    to="/"
                    class="text-sm text-muted-foreground hover:text-foreground"
                >
                    ← Dashboard
                </router-link>
                <h2 class="text-lg font-semibold text-foreground">
                    Trade Detail
                </h2>
            </div>
        </div>

        <div v-if="loading" class="text-sm text-muted-foreground py-8 text-center">
            Loading trade...
        </div>

        <div v-else-if="error" class="fr-card p-4 text-sm text-red-400">
            {{ error }}
        </div>

        <div v-else-if="detail" class="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <!-- Trade card -->
            <div class="fr-card p-4">
                <div class="fr-section-label mb-4">Trade</div>

                <div class="space-y-3">
                    <div class="flex items-center gap-2">
                        <BadgePill
                            :label="`${detail.trade.status === 'closed' ? 'Closed' : 'Open'} ${detail.trade.direction}`"
                            :extra-class="tradeDirectionBadgeClass(detail.trade.status, detail.trade.direction)"
                        />
                        <span class="text-base text-foreground">
                            {{ detail.trade.instrument.replace("_", "/") }}
                        </span>
                        <span class="font-mono text-sm text-muted-foreground">
                            {{ detail.trade.units }} units
                        </span>
                    </div>

                    <StatGrid
                        :items="tradeMetricItems"
                        columns-class="grid grid-cols-2 gap-3"
                    />

                    <div v-if="detail.trade.entry_reason" class="bg-background rounded-md p-3">
                        <div class="text-[10px] text-muted-foreground mb-1">
                            Entry Reason
                        </div>
                        <div class="text-xs font-mono text-foreground break-words">
                            {{ detail.trade.entry_reason }}
                        </div>
                    </div>

                    <div v-if="detail.trade.exit_reason" class="bg-background rounded-md p-3">
                        <div class="text-[10px] text-muted-foreground mb-1">
                            Exit Reason
                        </div>
                        <div class="text-xs font-mono text-foreground break-words">
                            {{ detail.trade.exit_reason }}
                        </div>
                    </div>

                    <div
                        v-if="detail.trade.oanda_trade_id"
                        class="text-[10px] text-muted-foreground font-mono"
                    >
                        OANDA trade ID: {{ detail.trade.oanda_trade_id }}
                    </div>
                </div>
            </div>

            <!-- Strategy card -->
            <div class="fr-card p-4">
                <div class="fr-section-label mb-4">Strategy</div>

                <div v-if="!detail.strategy" class="text-sm text-muted-foreground py-4">
                    Strategy reference missing — strategy may have been deleted.
                </div>

                <div v-else class="space-y-3">
                    <div class="flex items-center gap-2">
                        <span class="text-base text-foreground">
                            {{ strategyTypeLabel }}
                        </span>
                        <BadgePill
                            :label="detail.strategy.enabled ? 'Enabled' : 'Disabled'"
                            :extra-class="strategyEnabledBadgeClass(detail.strategy.enabled)"
                        />
                    </div>

                    <StatGrid
                        :items="strategyMetricItems"
                        columns-class="grid grid-cols-2 gap-3"
                    />

                    <div class="bg-background rounded-md p-3">
                        <div class="text-[10px] text-muted-foreground mb-2">
                            Parameters
                        </div>
                        <div class="space-y-1">
                            <div
                                v-for="(value, key) in detail.strategy.parameters"
                                :key="key"
                                class="flex justify-between text-xs font-mono"
                            >
                                <span class="text-muted-foreground">{{ key }}</span>
                                <span class="text-foreground">{{ formatParamValue(value) }}</span>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Live performance vs backtest -->
            <div class="fr-card p-4 lg:col-span-2">
                <div class="flex items-center justify-between mb-4">
                    <div class="fr-section-label mb-0 pb-0 border-b-0">
                        Live Performance for this Strategy
                    </div>
                    <span
                        v-if="edgeStatus"
                        class="inline-flex"
                    >
                        <BadgePill
                            :label="edgeStatus.label"
                            :extra-class="edgeStatus.color"
                        />
                    </span>
                </div>

                <div
                    v-if="!detail.live_aggregate"
                    class="text-sm text-muted-foreground py-4"
                >
                    No closed live trades for this strategy yet.
                </div>

                <div v-else class="space-y-3">
                    <StatGrid :items="liveMetricItems" />
                </div>
            </div>

            <!-- Backtest comparison card -->
            <div class="fr-card p-4 lg:col-span-2">
                <div class="fr-section-label mb-4">Source Backtest</div>

                <div v-if="!detail.backtest" class="text-sm text-muted-foreground py-4">
                    No source backtest linked. This strategy was not deployed from a backtest run.
                </div>

                <div v-else class="space-y-3">
                    <div class="text-sm text-foreground">
                        {{ detail.backtest.strategy_name || "Unnamed backtest" }}
                    </div>

                    <StatGrid :items="backtestMetricItems" />
                </div>
            </div>
        </div>
    </main>
</template>

<script setup lang="ts">
import BadgePill from "@/components/ui/BadgePill.vue";
import StatGrid from "@/components/ui/StatGrid.vue";
import { useTradeDetail } from "@/composables/useTradeDetail";
import {
    strategyEnabledBadgeClass,
    tradeDirectionBadgeClass,
} from "@/lib/domain-ui";

const {
    detail,
    loading,
    error,
    strategyTypeLabel,
    edgeStatus,
    tradeMetricItems,
    strategyMetricItems,
    liveMetricItems,
    backtestMetricItems,
    formatParamValue,
} = useTradeDetail();
</script>
