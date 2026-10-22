<template>
    <div class="fr-card p-4">
        <div class="flex items-center justify-between mb-3">
            <div class="flex items-center gap-3">
                <div class="fr-section-label mb-0 pb-0 border-b-0">
                    {{ instrument.replace("_", "/") }} · {{ granularity }}
                </div>
                <!-- Overlay legend -->
                <div class="flex items-center gap-2 flex-wrap">
                    <span
                        v-for="entry in legend"
                        :key="entry.name"
                        class="flex items-center gap-1 text-[10px] font-mono"
                        :style="{ color: entry.color }"
                    >
                        <span
                            class="inline-block h-0.5 w-3 rounded"
                            :style="{ backgroundColor: entry.color }"
                        />
                        {{ entry.label }}
                    </span>
                </div>
            </div>
            <div class="flex items-center gap-2">
                <label
                    class="flex items-center gap-1 text-[10px] text-muted-foreground cursor-pointer"
                    title="Entry/exit markers from the same backtest the pipeline gates run, including stop-loss and max-hold exits."
                >
                    <input v-model="showSignals" type="checkbox" class="h-3 w-3" />
                    signals
                </label>
                <span v-if="signalError" class="text-[10px] text-amber-400" :title="signalError">
                    signals unavailable
                </span>
                <span v-if="loading" class="text-[10px] text-muted-foreground">loading…</span>
                <span v-else-if="error" class="text-[10px] text-red-400">{{ error }}</span>
                <span v-else class="text-[10px] text-muted-foreground font-mono">
                    {{ candleCount }} candles
                </span>
            </div>
        </div>
        <!-- Fixed height: an auto-sized chart in a content-sized container
             feeds its own canvas height back into the layout and grows
             without bound. -->
        <div ref="chartEl" class="h-95" />
    </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import {
    ColorType,
    createChart,
    LineStyle,
    type IChartApi,
    type ISeriesApi,
    type SeriesMarker,
    type UTCTimestamp,
} from "lightweight-charts";

import type { ComponentInstance } from "@/composables/useStrategyEditor";
import {
    donchianSeries,
    macdSeries,
    maSeries,
    rsiSeries,
    zBandSeries,
    type LinePoint,
    type OhlcBar,
} from "@/lib/chartIndicators";
import type { CompositeStrategyConfig } from "@/lib/strategyCatalog";
import { api, getApiErrorMessage } from "@/services/api";

interface PreviewSignal {
    time: string;
    kind: "entry" | "exit";
    direction: "long" | "short";
}

interface SignalPreviewResponse {
    signals: PreviewSignal[];
}

interface ApiCandle {
    time: string;
    open: number;
    high: number;
    low: number;
    close: number;
    volume: number;
    complete: boolean;
}

interface CandlesResponse {
    instrument: string;
    granularity: string;
    candles: ApiCandle[];
}

const props = withDefaults(
    defineProps<{
        instrument: string;
        granularity: string;
        count?: number;
        components?: ComponentInstance[];
        config?: CompositeStrategyConfig | null;
    }>(),
    { count: 300, components: () => [], config: null },
);

const chartEl = ref<HTMLElement | null>(null);
const loading = ref(false);
const error = ref<string | null>(null);
const candleCount = ref(0);
const bars = ref<OhlcBar[]>([]);
const showSignals = ref(true);
const signalError = ref<string | null>(null);

let chart: IChartApi | null = null;
let candleSeries: ISeriesApi<"Candlestick"> | null = null;
let overlaySeries: Array<ISeriesApi<"Line"> | ISeriesApi<"Histogram">> = [];

// One hue per component instance, stable by position.
const PALETTE = ["#f59e0b", "#38bdf8", "#a78bfa", "#f472b6", "#34d399", "#fb923c"];

const OSCILLATOR_TYPES = new Set(["Macd", "RsiReversion"]);

const legend = computed(() =>
    props.components.map((c, idx) => ({
        name: c.name,
        label: `${c.name} (${c.type})`,
        color: PALETTE[idx % PALETTE.length],
    })),
);

function intParam(c: ComponentInstance, key: string): number {
    const v = Number(c.params[key]);
    return Number.isFinite(v) && v >= 1 ? Math.floor(v) : 0;
}

function floatParam(c: ComponentInstance, key: string): number {
    const v = Number(c.params[key]);
    return Number.isFinite(v) ? v : 0;
}

function addLine(
    data: LinePoint[],
    color: string,
    options: { dashed?: boolean; width?: 1 | 2; priceScaleId?: string } = {},
) {
    if (!chart || data.length === 0) return null;

    const line = chart.addLineSeries({
        color,
        lineWidth: options.width ?? 1,
        lineStyle: options.dashed ? LineStyle.Dashed : LineStyle.Solid,
        priceScaleId: options.priceScaleId ?? "right",
        priceLineVisible: false,
        lastValueVisible: false,
        crosshairMarkerVisible: false,
    });
    line.setData(data.map((p) => ({ time: p.time as UTCTimestamp, value: p.value })));
    overlaySeries.push(line);
    return line;
}

function rebuildOverlays() {
    if (!chart) return;

    for (const s of overlaySeries) {
        chart.removeSeries(s);
    }
    overlaySeries = [];

    const data = bars.value;
    if (data.length === 0) return;

    const hasOscillator = props.components.some((c) => OSCILLATOR_TYPES.has(c.type));

    // Reserve the bottom strip for oscillators (TradingView-style sub-pane).
    chart.priceScale("right").applyOptions({
        scaleMargins: hasOscillator ? { top: 0.05, bottom: 0.32 } : { top: 0.1, bottom: 0.08 },
    });

    props.components.forEach((c, idx) => {
        const color = PALETTE[idx % PALETTE.length];
        const faded = `${color}66`;
        // Each oscillator autoscales in its own price scale, pinned to the
        // same bottom strip.
        const oscOptions = {
            priceScaleId: `osc-${c.name}`,
        };

        switch (c.type) {
            case "TrendFollowing": {
                const maType = String(c.params.ma_type ?? "sma");
                addLine(maSeries(data, intParam(c, "fast_period"), maType), color);
                addLine(maSeries(data, intParam(c, "slow_period"), maType), faded, { width: 2 });
                break;
            }
            case "MaFilter": {
                const maType = String(c.params.ma_type ?? "sma");
                addLine(maSeries(data, intParam(c, "period"), maType), color, { width: 2 });
                break;
            }
            case "MeanReversion": {
                const bands = zBandSeries(
                    data,
                    intParam(c, "ma_period"),
                    floatParam(c, "entry_z_threshold"),
                );
                addLine(bands.middle, color);
                addLine(bands.upper, faded, { dashed: true });
                addLine(bands.lower, faded, { dashed: true });
                break;
            }
            case "Donchian": {
                const entry = donchianSeries(data, intParam(c, "entry_period"));
                const exit = donchianSeries(data, intParam(c, "exit_period"));
                addLine(entry.upper, color);
                addLine(entry.lower, color);
                addLine(exit.upper, faded, { dashed: true });
                addLine(exit.lower, faded, { dashed: true });
                break;
            }
            case "Macd": {
                const out = macdSeries(
                    data,
                    intParam(c, "fast_period"),
                    intParam(c, "slow_period"),
                    intParam(c, "signal_period"),
                );
                if (chart && out.histogram.length > 0) {
                    const hist = chart.addHistogramSeries({
                        priceScaleId: oscOptions.priceScaleId,
                        priceLineVisible: false,
                        lastValueVisible: false,
                    });
                    hist.setData(
                        out.histogram.map((p) => ({
                            time: p.time as UTCTimestamp,
                            value: p.value,
                            color: p.value >= 0 ? "#10b98155" : "#ef444455",
                        })),
                    );
                    overlaySeries.push(hist);
                }
                addLine(out.macd, color, oscOptions);
                addLine(out.signal, faded, { ...oscOptions, dashed: true });
                break;
            }
            case "RsiReversion": {
                const rsi = addLine(rsiSeries(data, intParam(c, "rsi_period")), color, oscOptions);
                if (rsi) {
                    for (const level of [floatParam(c, "oversold"), floatParam(c, "overbought")]) {
                        rsi.createPriceLine({
                            price: level,
                            color: faded,
                            lineWidth: 1,
                            lineStyle: LineStyle.Dotted,
                            axisLabelVisible: false,
                            title: "",
                        });
                    }
                }
                break;
            }
        }

        // Pin every oscillator scale to the bottom strip.
        if (OSCILLATOR_TYPES.has(c.type) && chart) {
            chart.priceScale(oscOptions.priceScaleId).applyOptions({
                scaleMargins: { top: 0.72, bottom: 0.02 },
            });
        }
    });
}

// --- Signal markers (entry/exit from Rust's signal-preview endpoint) ---

let markerTimer: ReturnType<typeof setTimeout> | null = null;
let markerRequestSeq = 0;

function scheduleMarkerRefresh() {
    if (markerTimer) clearTimeout(markerTimer);
    markerTimer = setTimeout(() => void refreshMarkers(), 400);
}

async function refreshMarkers() {
    if (!candleSeries) return;

    if (!showSignals.value || !props.config || bars.value.length === 0) {
        candleSeries.setMarkers([]);
        return;
    }

    const seq = ++markerRequestSeq;
    try {
        const body = await api.post<SignalPreviewResponse>("/strategy/signal-preview", {
            parameters: props.config,
            count: props.count,
        });
        // A newer request superseded this one while it was in flight.
        if (seq !== markerRequestSeq || !candleSeries) return;

        const firstBarTime = bars.value[0]?.time ?? 0;
        const lastBarTime = bars.value[bars.value.length - 1]?.time ?? 0;

        // The preview walks DB candles; the chart shows OANDA REST candles.
        // Their slots mostly coincide but not always, and lightweight-charts
        // throws if a marker's time doesn't exist in the series data — snap
        // each signal forward to the first chart bar at-or-after its time.
        const barTimes = bars.value.map((b) => b.time);
        const snapToBar = (t: number): number | null => {
            if (t > lastBarTime) return lastBarTime;
            let lo = 0;
            let hi = barTimes.length - 1;
            while (lo < hi) {
                const mid = (lo + hi) >> 1;
                if (barTimes[mid] < t) lo = mid + 1;
                else hi = mid;
            }
            return barTimes[lo] >= t ? barTimes[lo] : null;
        };

        const events = body.signals
            .map((s) => ({ ...s, unixTime: Date.parse(s.time) / 1000 }))
            .sort((a, b) => a.unixTime - b.unixTime);

        const visible: Array<(typeof events)[number] & { carried?: boolean }> = events.filter(
            (s) => s.unixTime >= firstBarTime,
        );

        // The walk evaluates bars from before the chart's first visible bar.
        // If the last off-screen event is an entry, the position is "carried"
        // into the window — show it clamped to the first bar so an on-screen
        // exit circle is never orphaned.
        const offscreen = events.filter((s) => s.unixTime < firstBarTime);
        const lastOffscreen = offscreen.length > 0 ? offscreen[offscreen.length - 1] : undefined;
        if (lastOffscreen?.kind === "entry") {
            visible.unshift({ ...lastOffscreen, unixTime: firstBarTime, carried: true });
        }

        const markers = visible.flatMap((s): SeriesMarker<UTCTimestamp>[] => {
            const snapped = snapToBar(s.unixTime);
            if (snapped == null) return [];
            const long = s.direction === "long";
            if (s.kind === "entry") {
                const label = long ? "Long" : "Short";
                return [
                    {
                        time: snapped as UTCTimestamp,
                        position: long ? "belowBar" : "aboveBar",
                        shape: long ? "arrowUp" : "arrowDown",
                        color: long ? "#10b981" : "#ef4444",
                        text: s.carried ? `${label} (prior)` : label,
                    },
                ];
            }
            return [
                {
                    time: snapped as UTCTimestamp,
                    position: long ? "aboveBar" : "belowBar",
                    shape: "circle",
                    color: "#7a7a8a",
                    text: "exit",
                },
            ];
        });

        candleSeries.setMarkers(markers);
        signalError.value = null;
    } catch (e) {
        // Config may be transiently invalid while typing — clear markers, but
        // surface the message so real failures aren't invisible.
        if (seq === markerRequestSeq) {
            candleSeries?.setMarkers([]);
            signalError.value = getApiErrorMessage(e, "signal preview failed");
        }
    }
}

async function load() {
    if (!candleSeries) return;
    loading.value = true;
    error.value = null;

    try {
        const body = await api.get<CandlesResponse>(
            `/candles?instrument=${props.instrument}&granularity=${props.granularity}&count=${props.count}`,
        );

        const data = body.candles
            .map((c) => ({
                time: Date.parse(c.time) / 1000,
                open: c.open,
                high: c.high,
                low: c.low,
                close: c.close,
            }))
            .sort((a, b) => a.time - b.time);

        bars.value = data;
        candleSeries.setData(
            data.map((b) => ({ ...b, time: b.time as UTCTimestamp })),
        );
        candleCount.value = data.length;
        rebuildOverlays();
        scheduleMarkerRefresh();
        chart?.timeScale().fitContent();
    } catch (e) {
        error.value = getApiErrorMessage(e, "Failed to load candles");
    } finally {
        loading.value = false;
    }
}

onMounted(() => {
    if (!chartEl.value) return;

    chart = createChart(chartEl.value, {
        autoSize: true,
        layout: {
            background: { type: ColorType.Solid, color: "transparent" },
            textColor: "#7a7a8a",
            fontSize: 10,
        },
        grid: {
            vertLines: { color: "rgba(122, 122, 138, 0.08)" },
            horzLines: { color: "rgba(122, 122, 138, 0.08)" },
        },
        timeScale: { timeVisible: true, borderColor: "rgba(122, 122, 138, 0.2)" },
        rightPriceScale: { borderColor: "rgba(122, 122, 138, 0.2)" },
        crosshair: { mode: 0 },
    });

    candleSeries = chart.addCandlestickSeries({
        upColor: "#10b981",
        downColor: "#ef4444",
        borderVisible: false,
        wickUpColor: "#10b981",
        wickDownColor: "#ef4444",
    });

    void load();
});

watch(
    () => [props.instrument, props.granularity, props.count],
    () => void load(),
);

watch(() => props.components, rebuildOverlays, { deep: true });
watch([() => props.config, showSignals], scheduleMarkerRefresh, { deep: true });

onBeforeUnmount(() => {
    if (markerTimer) clearTimeout(markerTimer);
    chart?.remove();
    chart = null;
    candleSeries = null;
    overlaySeries = [];
});
</script>
