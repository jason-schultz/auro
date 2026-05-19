<template>
    <section class="fr-card px-4 py-2.5 mb-3 flex flex-wrap items-center gap-3 text-xs">
        <div class="font-mono text-foreground">
            NAV {{ formatCad(nav) }}
        </div>
        <div
            class="font-mono"
            :class="pnlToday >= 0 ? 'text-emerald-400' : 'text-red-400'"
        >
            P&amp;L Today {{ pnlToday >= 0 ? '+' : '' }}{{ formatCad(pnlToday) }} ({{ pnlToday >= 0 ? '+' : '' }}{{ pnlTodayPct.toFixed(2) }}%)
        </div>

        <div class="ml-auto flex items-center gap-2">
            <span :title="tooltip('Rust', data?.rust.last_tick_seconds_ago)" class="pulse-pill" :class="pillClass(rustState())">● Rust</span>
            <span :title="tooltip('Opus', data?.opus.reconciler_last_run_seconds_ago)" class="pulse-pill" :class="pillClass(opusState())">● Opus</span>
            <span :title="tooltip('Regime', data?.opus.regime_detector_last_poll_seconds_ago)" class="pulse-pill" :class="pillClass(regimeState())">● Regime</span>
            <span :title="tooltip('Rules', data?.opus.rules_engine_last_push_seconds_ago)" class="pulse-pill" :class="pillClass(rulesState())">● Rules</span>
        </div>
    </section>
</template>

<script setup lang="ts">
import { computed } from "vue";
import { formatCadCurrency } from "@/lib/format";
import { useSystemPulse, type PulseState } from "@/composables/useSystemPulse";

const { data, fetchedAt, rustState, opusState, regimeState, rulesState } = useSystemPulse();

const nav = computed(() => data.value?.nav ?? 0);
const pnlToday = computed(() => data.value?.pnl_today ?? 0);
const pnlTodayPct = computed(() => data.value?.pnl_today_pct ?? 0);

function formatCad(value: number): string {
    return formatCadCurrency(value.toFixed(2));
}

function pillClass(state: PulseState): string {
    switch (state) {
        case "green":
            return "text-emerald-400";
        case "yellow":
            return "text-amber-400";
        case "closed":
            return "text-muted-foreground";
        default:
            return "text-red-400";
    }
}

function tooltip(label: string, seconds?: number | null): string {
    const age = seconds == null ? "n/a" : `${seconds}s ago`;
    const fetched = fetchedAt.value ? fetchedAt.value.toLocaleTimeString() : "n/a";
    return `${label}: ${age} (fetched ${fetched})`;
}
</script>

<style scoped>
.pulse-pill {
    font-size: 11px;
    font-weight: 600;
}
</style>
