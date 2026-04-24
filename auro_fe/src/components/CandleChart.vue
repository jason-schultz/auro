<template>
    <div class="flex flex-col h-full">
        <!-- Chart toolbar -->
        <div
            class="flex items-center justify-between border-b border-amber-500/8 px-4 py-2.5"
        >
            <div class="flex items-center gap-4">
                <select
                    v-model="selectedInstrument"
                    class="bg-[#0a0a0e] text-foreground text-sm rounded px-2 py-1 border border-amber-500/10 focus:outline-none focus:border-amber-500/30"
                >
                    <option
                        v-for="inst in availableInstruments"
                        :key="inst"
                        :value="inst"
                    >
                        {{ inst.replace("_", "/") }}
                    </option>
                </select>

                <div class="flex gap-1">
                    <button
                        v-for="g in granularities"
                        :key="g.value"
                        class="px-2 py-0.5 text-[11px] rounded transition-colors"
                        :class="
                            selectedGranularity === g.value
                                ? 'bg-primary/10 text-amber-400'
                                : 'text-[#4a4a5a] hover:text-foreground'
                        "
                        @click="selectedGranularity = g.value"
                    >
                        {{ g.label }}
                    </button>
                </div>
            </div>

            <div v-if="loading" class="text-[10px] text-muted-foreground">
                Loading...
            </div>
        </div>

        <!-- Chart container -->
        <div ref="chartContainer" class="flex-1 min-h-0" />

        <!-- Status bar -->
        <div
            class="border-t border-amber-500/8 px-4 py-1.5 flex items-center justify-between text-[10px]"
        >
            <div class="flex items-center gap-3">
                <span class="text-muted-foreground">OANDA Practice</span>
            </div>
            <span class="font-mono text-[#3a3a4a]"
                >{{ selectedInstrument.replace("_", "/") }} ·
                {{ selectedGranularity }}</span
            >
        </div>
    </div>
</template>

<script setup lang="ts">
import { ref, computed, watch, onMounted, onUnmounted, nextTick } from "vue";
import {
    createChart,
    type IChartApi,
    type ISeriesApi,
    ColorType,
} from "lightweight-charts";
import { useMarketStore } from "@/stores/market";
import { api } from "@/services/api";

const marketStore = useMarketStore();

const chartContainer = ref<HTMLElement | null>(null);
const loading = ref(false);

let chart: IChartApi | null = null;
let candleSeries: ISeriesApi<"Candlestick"> | null = null;

const availableInstruments = [
    "EUR_USD",
    "USD_CAD",
    "GBP_USD",
    "USD_JPY",
    "AUD_USD",
    "XAU_USD",
];

const granularities = [
    { label: "1m", value: "M1" },
    { label: "5m", value: "M5" },
    { label: "15m", value: "M15" },
    { label: "1H", value: "H1" },
    { label: "4H", value: "H4" },
    { label: "D", value: "D" },
];

const marketStore2 = useMarketStore();
const selectedInstrument = computed({
    get: () => marketStore2.selectedInstrument,
    set: (val: string) => marketStore2.selectInstrument(val),
});
const selectedGranularity = ref("M15");

function initChart() {
    if (!chartContainer.value) return;

    chart = createChart(chartContainer.value, {
        layout: {
            background: { type: ColorType.Solid, color: "transparent" },
            textColor: "#a1a1aa",
            fontFamily: "'Geist', sans-serif",
        },
        grid: {
            vertLines: { color: "#27272a" },
            horzLines: { color: "#27272a" },
        },
        crosshair: {
            vertLine: {
                labelBackgroundColor: "#18181b",
            },
            horzLine: {
                labelBackgroundColor: "#18181b",
            },
        },
        timeScale: {
            borderColor: "#27272a",
            timeVisible: true,
            secondsVisible: false,
        },
        rightPriceScale: {
            borderColor: "#27272a",
        },
    });

    candleSeries = chart.addCandlestickSeries({
        upColor: "#22c55e",
        downColor: "#ef4444",
        borderDownColor: "#ef4444",
        borderUpColor: "#22c55e",
        wickDownColor: "#ef4444",
        wickUpColor: "#22c55e",
    });

    handleResize();
}

function handleResize() {
    if (!chart || !chartContainer.value) return;
    const { width, height } = chartContainer.value.getBoundingClientRect();
    chart.resize(width, height);
}

async function loadCandles() {
    if (!candleSeries) return;

    loading.value = true;

    try {
        const data = await api.get<{
            instrument: string;
            granularity: string;
            candles: Array<{
                time: string;
                open: number;
                high: number;
                low: number;
                close: number;
                volume: number;
                complete: boolean;
            }>;
        }>(
            `/candles?instrument=${selectedInstrument.value}&granularity=${selectedGranularity.value}&count=200`,
        );

        const formatted = data.candles.map((c) => ({
            time: Math.floor(new Date(c.time).getTime() / 1000) as any,
            open: c.open,
            high: c.high,
            low: c.low,
            close: c.close,
        }));

        candleSeries.setData(formatted);
        chart?.timeScale().fitContent();
    } catch (e) {
        console.error("Failed to load candles:", e);
    } finally {
        loading.value = false;
    }
}

function granularityToMs(granularity: string): number {
    switch (granularity) {
        case "M1":
            return 60 * 1000;
        case "M5":
            return 5 * 60 * 1000;
        case "M15":
            return 15 * 60 * 1000;
        case "H1":
            return 60 * 60 * 1000;
        case "H4":
            return 4 * 60 * 60 * 1000;
        case "D":
            return 24 * 60 * 60 * 1000;
        default:
            return 60 * 1000;
    }
}

// Track the current bar being built from ticks
let currentBar: {
    time: number;
    open: number;
    high: number;
    low: number;
    close: number;
} | null = null;

// Watch for real-time price updates to update the last candle
watch(
    () => marketStore.prices[selectedInstrument.value],
    (tick) => {
        if (!tick || !candleSeries) return;

        const bid = parseFloat(tick.bid);
        const ask = parseFloat(tick.ask);
        const mid = (bid + ask) / 2;
        const tickTime = new Date(tick.time).getTime();

        const intervalMs = granularityToMs(selectedGranularity.value);
        const snappedTime = Math.floor(tickTime / intervalMs) * intervalMs;
        const timeInSeconds = Math.floor(snappedTime / 1000);

        if (currentBar && currentBar.time === timeInSeconds) {
            // Same candle — update close, extend high/low
            currentBar.close = mid;
            currentBar.high = Math.max(currentBar.high, mid);
            currentBar.low = Math.min(currentBar.low, mid);
        } else {
            // New candle
            currentBar = {
                time: timeInSeconds,
                open: mid,
                high: mid,
                low: mid,
                close: mid,
            };
        }

        candleSeries.update({
            time: currentBar.time as any,
            open: currentBar.open,
            high: currentBar.high,
            low: currentBar.low,
            close: currentBar.close,
        });
    },
);

// Reload when instrument or granularity changes
watch([selectedInstrument, selectedGranularity], () => {
    currentBar = null;
    loadCandles();
});

let resizeObserver: ResizeObserver | null = null;

onMounted(async () => {
    await nextTick();
    initChart();
    loadCandles();

    resizeObserver = new ResizeObserver(() => {
        handleResize();
    });
    if (chartContainer.value) {
        resizeObserver.observe(chartContainer.value);
    }
});

onUnmounted(() => {
    resizeObserver?.disconnect();
    chart?.remove();
    chart = null;
    candleSeries = null;
});
</script>
