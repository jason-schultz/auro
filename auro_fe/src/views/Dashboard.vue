<template>
    <main class="p-6">
        <ViewHeader title="Dashboard" />

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
            <!-- Account Summary -->
            <div class="lg:col-span-1 fr-card p-4">
                <div class="fr-section-label mb-4">Account Summary</div>

                <StateMessage
                    v-if="!account"
                    message="Loading account..."
                    :compact="true"
                />

                <div v-else class="space-y-3">
                    <div class="text-center mb-4">
                        <div
                            class="text-[10px] uppercase tracking-wider text-muted-foreground mb-1"
                        >
                            Net Asset Value
                        </div>
                        <div
                            class="text-2xl font-mono font-semibold text-foreground"
                        >
                            {{ formatCurrency(account.balance) }}
                        </div>
                    </div>

                    <StatGrid
                        :items="accountStatCards"
                        columns-class="grid grid-cols-2 gap-3"
                    />
                </div>
            </div>

            <!-- Open Positions -->
            <div class="lg:col-span-2">
                <DataTableScaffold
                    :loading="positionsLoading"
                    :empty="positions.length === 0"
                    loading-message="Loading positions..."
                    empty-message="No open positions"
                    card-class="p-4"
                    head-row-class="text-muted-foreground"
                >
                    <template #head>
                            <th
                                class="text-left pb-2 text-[10px] font-medium uppercase tracking-wider"
                            >
                                Instrument
                            </th>
                            <th
                                class="text-right pb-2 text-[10px] font-medium uppercase tracking-wider"
                            >
                                Side
                            </th>
                            <th
                                class="text-right pb-2 text-[10px] font-medium uppercase tracking-wider"
                            >
                                Units
                            </th>
                            <th
                                class="text-right pb-2 text-[10px] font-medium uppercase tracking-wider"
                            >
                                Entry
                            </th>
                            <th
                                class="text-right pb-2 text-[10px] font-medium uppercase tracking-wider"
                            >
                                Current
                            </th>
                            <th
                                class="text-center pb-2 text-[10px] font-medium uppercase tracking-wider"
                            >
                                State
                            </th>
                            <th
                                class="text-right pb-2 text-[10px] font-medium uppercase tracking-wider"
                            >
                                Stop
                            </th>
                            <th
                                class="text-right pb-2 text-[10px] font-medium uppercase tracking-wider"
                            >
                                Target
                            </th>
                            <th
                                class="text-right pb-2 text-[10px] font-medium uppercase tracking-wider"
                            >
                                P&L
                            </th>
                    </template>
                    <template #body>
                        <tr
                            v-for="pos in positions"
                            :key="pos.id"
                            class="border-b border-border"
                        >
                            <td class="py-2 text-foreground">
                                {{ pos.instrument.replace("_", "/") }}
                            </td>
                            <td class="py-2 text-right">
                                <BadgePill
                                    :label="pos.side"
                                    :extra-class="pos.side === 'Long' ? 'bg-emerald-500/10 text-emerald-400' : 'bg-red-500/10 text-red-400'"
                                />
                            </td>
                            <td
                                class="py-2 text-right font-mono text-foreground"
                            >
                                {{ pos.units }}
                            </td>
                            <td
                                class="py-2 text-right font-mono text-muted-foreground"
                            >
                                ${{ pos.entry }}
                            </td>
                            <td
                                class="py-2 text-right font-mono text-foreground"
                            >
                                ${{ pos.current }}
                            </td>
                            <td class="py-2 text-center">
                                <BadgePill
                                    :label="pos.stopLossState"
                                    :extra-class="stateColor(pos.stopLossState)"
                                />
                            </td>
                            <td
                                class="py-2 text-right font-mono text-muted-foreground"
                            >
                                <template v-if="pos.stopDisplay">
                                    <div>{{ pos.stopDisplay.priceLabel }}</div>
                                    <div
                                        class="text-[10px]"
                                        :class="pos.stopDisplay.distanceClass"
                                    >
                                        {{ pos.stopDisplay.distanceLabel }}
                                    </div>
                                </template>
                                <template v-else>—</template>
                            </td>
                            <td
                                class="py-2 text-right font-mono text-muted-foreground"
                            >
                                <template v-if="pos.targetDisplay">
                                    <div>${{ pos.targetDisplay.price }}</div>
                                    <div
                                        class="text-[10px]"
                                        :class="pos.targetDisplay.distanceClass"
                                    >
                                        {{ pos.targetDisplay.distanceLabel }}
                                    </div>
                                </template>
                                <template v-else>—</template>
                            </td>
                            <td
                                class="py-2 text-right font-mono font-medium"
                                :class="
                                    pos.pl >= 0
                                        ? 'text-emerald-400'
                                        : 'text-red-400'
                                "
                            >
                                {{ pos.pl >= 0 ? "+" : ""
                                }}{{ pos.pl.toFixed(2) }}
                            </td>
                        </tr>
                    </template>
                </DataTableScaffold>
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

            <!-- Manual Opportunities -->
            <div class="lg:col-span-1 fr-card p-4">
                <div class="fr-section-label mb-4">Manual Opportunities</div>

                <div class="text-sm text-muted-foreground py-8 text-center">
                    Coming soon — Wealthsimple / TSX signals
                </div>
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
import { computed } from "vue";
import { useDashboard } from "@/composables/useDashboard";
import BadgePill from "@/components/ui/BadgePill.vue";
import DataCard from "@/components/ui/DataCard.vue";
import DataTableScaffold from "@/components/ui/DataTableScaffold.vue";
import StatGrid from "@/components/ui/StatGrid.vue";
import StateMessage from "@/components/ui/StateMessage.vue";
import ViewHeader from "@/components/ui/ViewHeader.vue";

const {
    account,
    positions,
    positionsLoading,
    algoActivity,
    algoLoading,
    formatCurrency,
    actionColor,
    stateColor,
    formatPrice,
    reasonShort,
    exitReasonColor,
} = useDashboard();

const accountStatCards = computed(() => {
    if (!account.value) return [];

    return [
        {
            label: "Unrealized P&L",
            value: formatCurrency(account.value.unrealized_pl),
            valueClass: Number(account.value.unrealized_pl) >= 0 ? "text-emerald-400" : "text-red-400",
        },
        {
            label: "Realized P&L",
            value: formatCurrency(account.value.pl),
            valueClass: Number(account.value.pl) >= 0 ? "text-emerald-400" : "text-red-400",
        },
        {
            label: "Margin Used",
            value: formatCurrency(account.value.margin_used),
            valueClass: "text-foreground",
        },
        {
            label: "Margin Available",
            value: formatCurrency(account.value.margin_available),
            valueClass: "text-foreground",
        },
    ];
});
</script>