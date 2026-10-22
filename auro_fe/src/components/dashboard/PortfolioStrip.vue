<template>
    <section class="fr-card p-4 mb-4">
        <div class="flex items-center justify-between mb-3">
            <div class="fr-section-label mb-0 pb-0 border-b-0">Portfolio</div>
            <span v-if="error" class="text-[10px] text-red-400">{{ error }}</span>
        </div>

        <div v-if="loading" class="grid grid-cols-2 lg:grid-cols-5 gap-3">
            <div v-for="n in 5" :key="n" class="h-16 bg-muted/20 rounded-md animate-pulse" />
        </div>

        <div v-else class="grid grid-cols-2 lg:grid-cols-5 gap-3">
            <!-- Aggregate -->
            <div class="rounded-md bg-primary/5 border border-primary/15 p-3">
                <div class="text-[10px] text-muted-foreground mb-1">Total (CAD)</div>
                <div class="font-mono text-lg text-foreground">
                    {{ formatCadCurrency(totalCad) }}
                </div>
                <div class="text-[10px] text-muted-foreground mt-0.5">
                    {{ accounts.length }} accounts
                </div>
            </div>

            <!-- Per-account -->
            <div
                v-for="account in accounts"
                :key="`${account.broker}-${account.label}`"
                class="rounded-md bg-background p-3"
            >
                <div class="flex items-center gap-1.5 mb-1">
                    <span
                        class="text-[9px] font-mono uppercase px-1 py-0.5 rounded"
                        :class="brokerBadgeClass(account.broker)"
                    >
                        {{ account.broker }}
                    </span>
                    <span class="text-[10px] text-muted-foreground truncate">
                        {{ account.label }}
                    </span>
                </div>
                <div class="font-mono text-base text-foreground">
                    {{ formatCadCurrency(account.value) }}
                </div>
                <div class="text-[10px] mt-0.5 flex items-center gap-2">
                    <span
                        v-if="account.unrealized_pl != null"
                        :class="pnlClass(account.unrealized_pl)"
                    >
                        {{ account.unrealized_pl >= 0 ? "+" : ""
                        }}{{ formatCadCurrency(account.unrealized_pl) }} unrealized
                    </span>
                    <span class="text-muted-foreground">
                        {{ account.open_positions }} position{{
                            account.open_positions === 1 ? "" : "s"
                        }}
                    </span>
                </div>
            </div>
        </div>
    </section>
</template>

<script setup lang="ts">
import { usePortfolioSummary } from "@/composables/usePortfolioSummary";
import { pnlClass } from "@/lib/domain-ui";
import { formatCadCurrency } from "@/lib/format";

const { loading, error, totalCad, accounts } = usePortfolioSummary();

function brokerBadgeClass(broker: string): string {
    switch (broker) {
        case "oanda":
            return "bg-amber-500/15 text-amber-400";
        case "wealthsimple":
            return "bg-sky-500/15 text-sky-400";
        default:
            return "bg-muted text-muted-foreground";
    }
}
</script>
