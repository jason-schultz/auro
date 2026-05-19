<template>
    <section class="fr-card p-4">
        <div class="fr-section-label mb-4">Performance KPIs</div>

        <div v-if="loading" class="grid grid-cols-2 lg:grid-cols-4 gap-3">
            <div v-for="n in 8" :key="n" class="h-20 bg-muted/20 rounded-md animate-pulse" />
        </div>

        <div v-else-if="!kpis" class="text-sm text-muted-foreground py-8 text-center">
            Unable to load KPIs
        </div>

        <div v-else class="grid grid-cols-2 lg:grid-cols-4 gap-3">
            <button class="kpi-tile" @click="goToFilter('total')">
                <div class="kpi-label">Total P&amp;L CAD</div>
                <div class="kpi-value" :class="kpis.total_pnl_cad >= 0 ? 'text-emerald-400' : 'text-red-400'">{{ formatCad(kpis.total_pnl_cad) }}</div>
            </button>

            <button class="kpi-tile" @click="goToFilter('wins')">
                <div class="kpi-label">Win Rate %</div>
                <div class="kpi-value">{{ kpis.win_rate_pct.toFixed(1) }}%</div>
            </button>

            <button class="kpi-tile" @click="goToFilter('profit_factor')">
                <div class="kpi-label">Profit Factor</div>
                <div class="kpi-value">{{ kpis.profit_factor == null ? '—' : kpis.profit_factor.toFixed(2) }}</div>
            </button>

            <button class="kpi-tile" @click="goToFilter('expectancy')">
                <div class="kpi-label">Expectancy CAD</div>
                <div class="kpi-value" :class="kpis.expectancy_cad >= 0 ? 'text-emerald-400' : 'text-red-400'">{{ formatCad(kpis.expectancy_cad) }}</div>
            </button>

            <button class="kpi-tile" @click="goToInstrument(bestInstrument?.instrument)">
                <div class="kpi-label">Best Instrument</div>
                <div class="kpi-value">{{ bestInstrument?.instrument ?? '—' }}</div>
                <div class="kpi-meta" :class="(bestInstrument?.pnl_cad ?? 0) >= 0 ? 'text-emerald-400' : 'text-red-400'">{{ bestInstrument ? formatCad(bestInstrument.pnl_cad) : '—' }}</div>
            </button>

            <button class="kpi-tile" @click="goToInstrument(worstInstrument?.instrument)">
                <div class="kpi-label">Worst Instrument</div>
                <div class="kpi-value">{{ worstInstrument?.instrument ?? '—' }}</div>
                <div class="kpi-meta" :class="(worstInstrument?.pnl_cad ?? 0) >= 0 ? 'text-emerald-400' : 'text-red-400'">{{ worstInstrument ? formatCad(worstInstrument.pnl_cad) : '—' }}</div>
            </button>

            <button class="kpi-tile" @click="goToRegime(bestRegime?.regime)">
                <div class="kpi-label">Best Regime At Entry</div>
                <div class="kpi-value">{{ bestRegime?.regime ?? '—' }}</div>
                <div class="kpi-meta" :class="(bestRegime?.pnl_cad ?? 0) >= 0 ? 'text-emerald-400' : 'text-red-400'">{{ bestRegime ? formatCad(bestRegime.pnl_cad) : '—' }}</div>
            </button>

            <button class="kpi-tile" @click="goToRegime(worstRegime?.regime)">
                <div class="kpi-label">Worst Regime At Entry</div>
                <div class="kpi-value">{{ worstRegime?.regime ?? '—' }}</div>
                <div class="kpi-meta" :class="(worstRegime?.pnl_cad ?? 0) >= 0 ? 'text-emerald-400' : 'text-red-400'">{{ worstRegime ? formatCad(worstRegime.pnl_cad) : '—' }}</div>
            </button>
        </div>
    </section>
</template>

<script setup lang="ts">
import { computed, onMounted } from "vue";
import { useRouter } from "vue-router";
import { formatCadCurrency } from "@/lib/format";
import { useJournalKpis } from "@/composables/useJournalKpis";

const router = useRouter();
const { kpis, loading, load } = useJournalKpis();

const bestInstrument = computed(() => kpis.value?.by_instrument?.[0]);
const worstInstrument = computed(() => {
    const list = kpis.value?.by_instrument;
    return list && list.length ? list[list.length - 1] : null;
});

const bestRegime = computed(() => kpis.value?.by_regime_at_entry?.[0]);
const worstRegime = computed(() => {
    const list = kpis.value?.by_regime_at_entry;
    return list && list.length ? list[list.length - 1] : null;
});

function formatCad(value: number): string {
    return formatCadCurrency(value.toFixed(2));
}

function goToFilter(filter: string) {
    void router.push({ path: "/journal", query: { filter } });
}

function goToInstrument(instrument?: string) {
    if (!instrument) return;
    void router.push({ path: "/journal", query: { instrument } });
}

function goToRegime(regime?: string) {
    if (!regime) return;
    void router.push({ path: "/journal", query: { regime } });
}

onMounted(async () => {
    await load();
});
</script>

<style scoped>
.kpi-tile {
    text-align: left;
    border: 1px solid color-mix(in oklab, var(--color-border) 60%, transparent);
    border-radius: 0.5rem;
    background: color-mix(in oklab, var(--color-background) 75%, transparent);
    padding: 0.75rem;
    transition: border-color 140ms ease;
}

.kpi-tile:hover {
    border-color: color-mix(in oklab, var(--color-primary) 35%, transparent);
}

.kpi-label {
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--color-muted-foreground);
    margin-bottom: 0.2rem;
}

.kpi-value {
    font-size: 0.95rem;
    color: var(--color-foreground);
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-weight: 600;
}

.kpi-meta {
    font-size: 10px;
    margin-top: 0.2rem;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}
</style>
