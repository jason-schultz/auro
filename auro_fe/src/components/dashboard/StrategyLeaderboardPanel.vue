<template>
    <DataCard
        :loading="loading"
        :empty="rows.length === 0"
        loading-message="Loading strategies..."
        empty-message="No strategies in the universe yet."
        card-class="p-4 h-full"
        content-class=""
    >
        <div class="flex items-center justify-between mb-4">
            <div class="fr-section-label mb-0 pb-0 border-b-0">
                Strategy Leaderboard
            </div>
            <span class="text-[10px] text-muted-foreground font-mono">
                closed trades · last 30d
            </span>
        </div>

        <table class="w-full text-xs">
            <thead>
                <tr class="text-[10px] text-muted-foreground text-left">
                    <th class="pb-2 font-normal">Strategy</th>
                    <th class="pb-2 font-normal text-right">Trades</th>
                    <th class="pb-2 font-normal text-right">Win %</th>
                    <th class="pb-2 font-normal text-right">P&amp;L (CAD)</th>
                    <th class="pb-2 font-normal text-right">Open</th>
                </tr>
            </thead>
            <tbody>
                <tr
                    v-for="row in rows"
                    :key="row.strategy_id"
                    class="border-t border-border/40"
                >
                    <td class="py-2">
                        <div class="flex items-center gap-1.5">
                            <span
                                class="h-1.5 w-1.5 rounded-full shrink-0"
                                :class="row.enabled ? 'bg-emerald-500' : 'bg-muted-foreground/40'"
                                :title="row.enabled ? 'Enabled' : 'Disabled'"
                            />
                            <span class="text-foreground">
                                {{ row.instrument.replace("_", "/") }}
                            </span>
                            <span class="text-[10px] text-muted-foreground font-mono">
                                {{ row.granularity }}
                            </span>
                            <StrategyTypeBadge :type="row.strategy_type" />
                        </div>
                    </td>
                    <td class="py-2 text-right font-mono">{{ row.trades }}</td>
                    <td class="py-2 text-right font-mono">
                        {{ row.trades > 0 ? `${row.win_rate_pct.toFixed(0)}%` : "—" }}
                    </td>
                    <td
                        class="py-2 text-right font-mono"
                        :class="row.trades > 0 ? pnlClass(row.pnl_cad) : 'text-muted-foreground'"
                    >
                        {{ row.trades > 0 ? formatCadCurrency(row.pnl_cad) : "—" }}
                    </td>
                    <td class="py-2 text-right font-mono text-muted-foreground">
                        {{ row.open_trades }}
                    </td>
                </tr>
            </tbody>
        </table>
        <p v-if="error" class="mt-2 text-[10px] text-red-400">{{ error }}</p>
    </DataCard>
</template>

<script setup lang="ts">
import { useStrategyPerformance } from "@/composables/useStrategyPerformance";
import DataCard from "@/components/ui/DataCard.vue";
import StrategyTypeBadge from "@/components/ui/StrategyTypeBadge.vue";
import { pnlClass } from "@/lib/domain-ui";
import { formatCadCurrency } from "@/lib/format";

const { loading, error, rows } = useStrategyPerformance();
</script>
