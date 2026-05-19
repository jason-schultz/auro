<template>
    <section class="fr-card p-4">
        <div class="flex items-center justify-between mb-4 gap-3">
            <div>
                <div class="text-[10px] uppercase tracking-wider text-muted-foreground">Equity Curve</div>
                <div class="text-lg font-semibold text-foreground">Net Asset Value (NAV) {{ formatCad(summary.nav) }}</div>
                <div
                    class="text-xs font-mono"
                    :class="summary.delta >= 0 ? 'text-emerald-400' : 'text-red-400'"
                >
                    {{ summary.delta >= 0 ? "+" : "" }}{{ formatCad(summary.delta) }}
                    ({{ summary.delta >= 0 ? "+" : "" }}{{ summary.deltaPct.toFixed(2) }}%)
                </div>
                <div class="mt-2 flex items-center gap-4 text-[10px] font-mono text-muted-foreground">
                    <span class="inline-flex items-center gap-1.5">
                        <span class="h-0.5 w-4 rounded bg-amber-500" />
                        NAV
                    </span>
                    <span class="inline-flex items-center gap-1.5">
                        <span class="h-0 w-4 border-t border-dashed border-red-400/70" />
                        Running Peak
                    </span>
                </div>
                <div class="mt-1.5 text-[10px] font-mono text-muted-foreground">
                    Risk Signal:
                    <span class="font-semibold" :class="risk.levelClass">{{ risk.level }}</span>
                    <span class="ml-1">| DD now {{ risk.currentDrawdownPct.toFixed(2) }}%</span>
                    <span class="ml-1">| Max DD {{ risk.maxDrawdownPct.toFixed(2) }}%</span>
                </div>
            </div>

            <div class="flex items-center gap-1 bg-muted/30 rounded-lg p-1">
                <button
                    v-for="item in ranges"
                    :key="item"
                    class="px-2.5 py-1 rounded text-[11px] font-medium transition-colors"
                    :class="range === item ? 'bg-primary/10 text-amber-400' : 'text-muted-foreground hover:text-foreground'"
                    @click="range = item"
                >
                    {{ item }}
                </button>
            </div>
        </div>

        <div class="relative h-64 rounded-lg border border-border/60 overflow-hidden">
            <div
                ref="chartContainer"
                class="absolute inset-0"
            />

            <div
                v-if="loading"
                class="absolute inset-0 bg-muted/20 animate-pulse"
            />

            <div
                v-else-if="error"
                class="absolute inset-0 flex items-center justify-center text-sm text-red-400"
            >
                {{ error }}
            </div>

            <div
                v-else-if="points.length === 0"
                class="absolute inset-0 flex items-center justify-center text-sm text-muted-foreground"
            >
                No snapshots yet — first equity point arrives within 60 seconds
            </div>
        </div>
    </section>
</template>

<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import {
    ColorType,
    createChart,
    type IChartApi,
    type ISeriesApi,
    type LineData,
    LineStyle,
} from "lightweight-charts";
import { useEquityCurve } from "@/composables/useEquityCurve";
import { formatCadCurrency } from "@/lib/format";

const ranges = ["1D", "1W", "1M", "3M", "ALL"] as const;

const chartContainer = ref<HTMLElement | null>(null);
let chart: IChartApi | null = null;
let navSeries: ISeriesApi<"Line"> | null = null;
let peakSeries: ISeriesApi<"Line"> | null = null;
let resizeObserver: ResizeObserver | null = null;

const { range, points, summary, loading, error, load } = useEquityCurve();

const risk = computed(() => {
    if (points.value.length === 0) {
        return {
            currentDrawdownPct: 0,
            maxDrawdownPct: 0,
            level: "Low",
            levelClass: "text-emerald-400",
        };
    }

    let peak = Number.NEGATIVE_INFINITY;
    let maxDrawdownPct = 0;

    for (const p of points.value) {
        peak = Math.max(peak, p.nav);
        if (peak > 0) {
            const drawdownPct = ((peak - p.nav) / peak) * 100;
            maxDrawdownPct = Math.max(maxDrawdownPct, drawdownPct);
        }
    }

    const lastNav = points.value[points.value.length - 1]?.nav ?? 0;
    const currentDrawdownPct = peak > 0 ? ((peak - lastNav) / peak) * 100 : 0;

    if (currentDrawdownPct >= 1.5) {
        return {
            currentDrawdownPct,
            maxDrawdownPct,
            level: "Elevated",
            levelClass: "text-red-400",
        };
    }

    if (currentDrawdownPct >= 0.5) {
        return {
            currentDrawdownPct,
            maxDrawdownPct,
            level: "Guarded",
            levelClass: "text-amber-400",
        };
    }

    return {
        currentDrawdownPct,
        maxDrawdownPct,
        level: "Low",
        levelClass: "text-emerald-400",
    };
});

function formatCad(value: number): string {
    return formatCadCurrency(value.toFixed(2));
}

function toLineData(): { nav: LineData[]; peaks: LineData[] } {
    if (points.value.length === 1) {
        const only = points.value[0];
        const epochMs = new Date(only.timestamp).getTime();
        if (!Number.isNaN(epochMs)) {
            const t = Math.floor(epochMs / 1000);
            const t0 = t - 60;
            const v = only.nav;
            return {
                nav: [
                    { time: t0 as LineData["time"], value: v },
                    { time: t as LineData["time"], value: v },
                ],
                peaks: [
                    { time: t0 as LineData["time"], value: v },
                    { time: t as LineData["time"], value: v },
                ],
            };
        }
    }

    let runningMax = Number.NEGATIVE_INFINITY;

    const nav: LineData[] = [];
    const peaks: LineData[] = [];

    for (const p of points.value) {
        const epochMs = new Date(p.timestamp).getTime();
        if (Number.isNaN(epochMs)) continue;
        const t = Math.floor(epochMs / 1000) as LineData["time"];
        runningMax = Math.max(runningMax, p.nav);

        nav.push({ time: t, value: p.nav });
        peaks.push({ time: t, value: runningMax });
    }

    return { nav, peaks };
}

function initChart() {
    if (!chartContainer.value) return;

    const rect = chartContainer.value.getBoundingClientRect();
    const width = Math.max(1, Math.floor(rect.width || chartContainer.value.clientWidth || 0));
    const height = Math.max(1, Math.floor(rect.height || chartContainer.value.clientHeight || 0));

    chart = createChart(chartContainer.value, {
        width,
        height,
        layout: {
            background: { type: ColorType.Solid, color: "transparent" },
            textColor: "#a1a1aa",
            fontFamily: "'Geist', sans-serif",
        },
        grid: {
            vertLines: { color: "#27272a" },
            horzLines: { color: "#27272a" },
        },
        rightPriceScale: {
            borderColor: "#27272a",
        },
        timeScale: {
            borderColor: "#27272a",
            timeVisible: true,
            secondsVisible: false,
        },
    });

    navSeries = chart.addLineSeries({
        color: "#f59e0b",
        lineWidth: 2,
        priceLineVisible: false,
        lastValueVisible: true,
    });

    peakSeries = chart.addLineSeries({
        color: "rgba(239,68,68,0.45)",
        lineWidth: 1,
        lineStyle: LineStyle.Dashed,
        priceLineVisible: false,
        lastValueVisible: false,
    });

    handleResize();

    if (!resizeObserver && chartContainer.value) {
        resizeObserver = new ResizeObserver(() => {
            handleResize();
            renderChart();
        });
        resizeObserver.observe(chartContainer.value);
    }
}

function handleResize() {
    if (!chart || !chartContainer.value) return;
    const { width, height } = chartContainer.value.getBoundingClientRect();
    if (width > 0 && height > 0) {
        chart.resize(width, height);
    }
}

function renderChart() {
    if (!chart || !navSeries || !peakSeries) return;

    const data = toLineData();
    navSeries.setData(data.nav);
    peakSeries.setData(data.peaks);
    chart.timeScale().fitContent();
}

async function ensureChartReady() {
    if (chart) return;
    await nextTick();
    initChart();
}

watch(
    points,
    async () => {
        await ensureChartReady();
        renderChart();
    },
    { deep: true },
);

onMounted(async () => {
    window.addEventListener("resize", handleResize);
    await ensureChartReady();
    await load();
    renderChart();
});

onBeforeUnmount(() => {
    window.removeEventListener("resize", handleResize);
    resizeObserver?.disconnect();
    resizeObserver = null;
    chart?.remove();
    chart = null;
});
</script>
