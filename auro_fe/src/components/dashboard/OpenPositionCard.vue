<template>
    <article class="fr-card p-4">
        <div class="flex items-start justify-between mb-3">
            <div>
                <div class="text-sm font-semibold text-foreground">
                    {{ position.instrument }}
                    <span class="text-muted-foreground font-normal px-2">{{ position.direction }}</span>
                    <span class="text-muted-foreground font-mono text-xs">{{ Math.abs(Number(position.units)) }} units</span>
                </div>
                <div class="text-xs text-muted-foreground font-mono">
                    Entry {{ position.entry_price.toFixed(3) }} @ {{ formatEntryTime(position.entry_time) }}
                </div>
            </div>
            <span class="px-2 py-0.5 rounded text-[10px] font-medium" :class="statePillClass(position.stop_loss_state)">
                {{ position.stop_loss_state }}
            </span>
        </div>

        <div class="flex items-center justify-between mb-2 text-xs font-mono">
            <span class="text-muted-foreground">Now: {{ currentPriceLabel }}</span>
            <span :class="(position.pnl_pct ?? 0) >= 0 ? 'text-emerald-400' : 'text-red-400'">
                {{ (position.pnl_pct ?? 0) >= 0 ? '+' : '' }}{{ ((position.pnl_pct ?? 0) * 100).toFixed(2) }}%
            </span>
        </div>

        <div ref="sparklineEl" class="h-20 rounded border border-border/50 mb-3" />

        <div class="grid grid-cols-2 gap-3 mb-3 text-xs">
            <div>
                <div class="text-muted-foreground mb-1">MFE {{ pct(position.mfe_pct) }}</div>
                <div class="flex gap-1">
                    <span v-for="i in 5" :key="`mfe-${i}`" class="h-1.5 flex-1 rounded" :class="mfeSegments >= i ? 'bg-emerald-400/70' : 'bg-muted/50'" />
                </div>
            </div>
            <div>
                <div class="text-muted-foreground mb-1">MAE {{ pct(position.mae_pct) }}</div>
                <div class="flex gap-1">
                    <span v-for="i in 5" :key="`mae-${i}`" class="h-1.5 flex-1 rounded" :class="maeSegments >= i ? 'bg-red-400/70' : 'bg-muted/50'" />
                </div>
            </div>
        </div>

        <div class="text-xs font-mono space-y-1">
            <div class="flex justify-between">
                <span class="text-muted-foreground">SL</span>
                <span>{{ priceOrDash(position.stop_loss_price) }}</span>
            </div>
            <div class="flex justify-between">
                <span class="text-muted-foreground">TP</span>
                <span>{{ priceOrDash(position.take_profit_price) }}</span>
            </div>
            <div class="flex justify-between">
                <span class="text-muted-foreground">Notional</span>
                <span>{{ position.notional_pct_nav.toFixed(2) }}% NAV</span>
            </div>
            <div class="flex justify-between">
                <span class="text-muted-foreground">Risk if SL</span>
                <span :class="riskLabelClass">{{ riskLabel }}</span>
            </div>
        </div>
    </article>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { ColorType, createChart, LineStyle, type IChartApi, type ISeriesApi, type LineData } from "lightweight-charts";
import type { OpenPositionCardData } from "@/composables/useOpenPositions";

const props = defineProps<{
    position: OpenPositionCardData;
}>();

const sparklineEl = ref<HTMLElement | null>(null);
let chart: IChartApi | null = null;
let series: ISeriesApi<"Line"> | null = null;

const mfeSegments = computed(() => Math.min(5, Math.max(0, Math.round(Math.abs((props.position.mfe_pct ?? 0) * 100) / 1.5))));
const maeSegments = computed(() => Math.min(5, Math.max(0, Math.round(Math.abs((props.position.mae_pct ?? 0) * 100) / 1.5))));

const currentPriceLabel = computed(() => {
    const cp = props.position.current_price ?? props.position.entry_price;
    return cp.toFixed(3);
});

const riskAmount = computed(() => {
    const sl = props.position.stop_loss_price;
    if (sl == null) return null;

    const unitsAbs = Math.abs(Number(props.position.units));
    const entry = props.position.entry_price;

    if (props.position.stop_loss_state === "Breakeven") return 0;

    if (props.position.direction === "Long") {
        return (entry - sl) * unitsAbs;
    }

    return (sl - entry) * unitsAbs;
});

const riskLabel = computed(() => {
    if (props.position.stop_loss_state === "Breakeven") return "no risk";
    if (props.position.stop_loss_state === "Trailing") {
        const val = riskAmount.value ?? 0;
        if (val < 0) return `+$${Math.abs(val).toFixed(2)} locked`;
        return `$${val.toFixed(2)} at risk`;
    }
    if (riskAmount.value == null) return "—";
    return `$${Math.max(0, riskAmount.value).toFixed(2)}`;
});

const riskLabelClass = computed(() => {
    if (props.position.stop_loss_state === "Breakeven") return "text-emerald-400";
    if (props.position.stop_loss_state === "Trailing") return "text-blue-400";
    return "text-foreground";
});

function pct(v: number | null): string {
    if (v == null) return "—";
    return `${v >= 0 ? '+' : ''}${(v * 100).toFixed(2)}%`;
}

function priceOrDash(v: number | null): string {
    return v == null ? "—" : v.toFixed(3);
}

function formatEntryTime(entryTime: string | null): string {
    if (!entryTime) return "—";
    const d = new Date(entryTime);
    return d.toLocaleTimeString();
}

function statePillClass(state: string): string {
    switch (state) {
        case "Initial":
            return "bg-muted text-muted-foreground";
        case "Breakeven":
            return "bg-blue-500/15 text-blue-400";
        case "Trailing":
            return "bg-emerald-500/15 text-emerald-400";
        default:
            return "bg-secondary text-muted-foreground";
    }
}

function initChart() {
    if (!sparklineEl.value) return;

    chart = createChart(sparklineEl.value, {
        layout: {
            background: { type: ColorType.Solid, color: "transparent" },
            textColor: "#a1a1aa",
        },
        grid: {
            vertLines: { visible: false },
            horzLines: { visible: false },
        },
        timeScale: {
            visible: false,
            borderVisible: false,
        },
        rightPriceScale: {
            visible: false,
            borderVisible: false,
        },
        crosshair: {
            vertLine: { visible: false },
            horzLine: { visible: false },
        },
    });

    series = chart.addLineSeries({
        color: "#f59e0b",
        lineWidth: 2,
        priceLineVisible: false,
        lastValueVisible: false,
    });

    renderSparkline();
}

function renderSparkline() {
    if (!chart || !series) return;

    const points: LineData[] = props.position.sparkline.map((c) => ({
        time: Math.floor(new Date(c.timestamp).getTime() / 1000) as LineData["time"],
        value: c.close,
    }));

    series.setData(points);

    if (props.position.stop_loss_price != null) {
        series.createPriceLine({
            price: props.position.stop_loss_price,
            color: "#ef4444",
            lineWidth: 1,
            lineStyle: LineStyle.Dashed,
            axisLabelVisible: false,
            title: "SL",
        });
    }

    if (props.position.take_profit_price != null) {
        series.createPriceLine({
            price: props.position.take_profit_price,
            color: "#22c55e",
            lineWidth: 1,
            lineStyle: LineStyle.Dashed,
            axisLabelVisible: false,
            title: "TP",
        });
    }

    chart.timeScale().fitContent();
}

watch(
    () => props.position.sparkline,
    () => renderSparkline(),
    { deep: true },
);

onMounted(() => {
    initChart();
});

onBeforeUnmount(() => {
    chart?.remove();
    chart = null;
});
</script>
