<template>
    <article class="fr-card p-4">
        <div class="flex items-start justify-between mb-3">
            <div>
                <div class="text-sm font-semibold text-foreground">
                    {{ position.instrument }}
                    <span class="px-2 py-0.5 mx-1 rounded text-[10px] font-medium align-middle" :class="directionPillClass(position.direction)">
                        {{ position.direction }}
                    </span>
                    <span class="text-muted-foreground font-mono text-xs">{{ Math.abs(Number(position.units)) }} units · {{ costBasisLabel }}</span>
                </div>
                <div class="text-xs text-muted-foreground font-mono">
                    Entry {{ position.entry_price.toFixed(5) }} @ {{ formatEntryTime(position.entry_time) }}
                </div>
            </div>
            <span class="px-2 py-0.5 rounded text-[10px] font-medium" :class="statePillClass(position.stop_loss_state)">
                {{ position.stop_loss_state }}
            </span>
        </div>

        <div class="flex items-center justify-between mb-2 text-xs font-mono">
            <span class="text-muted-foreground">Now: {{ currentPriceLabel }}</span>
            <span :class="(position.pnl_pct ?? 0) >= 0 ? 'text-emerald-400' : 'text-red-400'">
                {{ (position.pnl_pct ?? 0) >= 0 ? '+' : '' }}{{ ((position.pnl_pct ?? 0) * 100).toFixed(3) }}%
            </span>
        </div>

        <div ref="sparklineEl" class="h-24 rounded border border-border/50 mb-1" />
        <div class="text-[10px] text-muted-foreground font-mono mb-3 text-right">
            {{ sparklineSpanLabel }}
        </div>

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
                <span class="text-muted-foreground">TSL</span>
                <span>{{ priceOrDash(position.trailing_stop_loss_price) }}</span>
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
import { ColorType, createChart, LineStyle, type AutoscaleInfo, type IChartApi, type IPriceLine, type ISeriesApi, type LineData } from "lightweight-charts";
import type { OpenPositionCardData } from "@/composables/useOpenPositions";

const props = defineProps<{
    position: OpenPositionCardData;
}>();

const sparklineEl = ref<HTMLElement | null>(null);
let chart: IChartApi | null = null;
let series: ISeriesApi<"Line"> | null = null;
let priceLines: IPriceLine[] = [];

const mfeSegments = computed(() => Math.min(5, Math.max(0, Math.round(Math.abs((props.position.mfe_pct ?? 0) * 100) / 1.5))));
const maeSegments = computed(() => Math.min(5, Math.max(0, Math.round(Math.abs((props.position.mae_pct ?? 0) * 100) / 1.5))));

const currentPriceLabel = computed(() => {
    const cp = props.position.current_price ?? props.position.entry_price;
    return cp.toFixed(5);
});

const sparklineSpanLabel = computed(() => {
    const n = props.position.sparkline.length;
    if (n === 0) return "—";
    const gran = props.position.granularity ?? "?";
    return `${n} × ${gran}`;
});

// Notional contract value at entry: entry_price × |units|. This is the contract
// size, NOT the capital committed — for CFD/leveraged trades, the actual cash
// committed is margin (~5% for metals on OANDA practice). Shown for trade-size
// legibility at a glance.
const costBasisLabel = computed(() => {
    const units = Math.abs(Number(props.position.units));
    const value = units * props.position.entry_price;
    return value.toLocaleString("en-US", {
        style: "currency",
        currency: "USD",
        maximumFractionDigits: 0,
    });
});

const riskAmount = computed(() => {
    // In Trailing state, OANDA cancels the regular SL order and the actual
    // stop is the trailing_stop_loss_price. In every other state, stop_loss_price
    // is the live stop.
    const sl = props.position.stop_loss_state === "Trailing"
        ? props.position.trailing_stop_loss_price
        : props.position.stop_loss_price;
    if (sl == null) return null;

    const unitsAbs = Math.abs(Number(props.position.units));
    const entry = props.position.entry_price;

    if (props.position.stop_loss_state === "Breakeven") return 0;

    if (props.position.direction === "Long") {
        return (entry - sl) * unitsAbs;
    }

    return (sl - entry) * unitsAbs;
});

// Quote currency parsed from the instrument name (e.g., XAG_USD → USD).
// Used to label the risk display and decide whether currency conversion
// to account currency (CAD) is needed.
const quoteCurrency = computed(() => {
    const parts = props.position.instrument.split("_");
    return parts[parts.length - 1] ?? "USD";
});

// Convert a value in quote currency to account currency (CAD). Returns null
// if conversion isn't possible (rate unavailable, or unsupported quote currency).
// Currently only handles USD → CAD via usd_to_cad_rate; other quote currencies
// (JPY, EUR, etc.) need separate cross-rate lookups and are not converted.
function toAccountCurrency(amount: number): number | null {
    if (quoteCurrency.value === "CAD") return amount;
    if (quoteCurrency.value === "USD" && props.position.usd_to_cad_rate != null) {
        return amount * props.position.usd_to_cad_rate;
    }
    return null;
}

const riskLabel = computed(() => {
    if (props.position.stop_loss_state === "Breakeven") return "no risk";
    if (props.position.stop_loss_state === "Trailing") {
        const val = riskAmount.value ?? 0;
        if (val < 0) {
            const cadVal = toAccountCurrency(Math.abs(val));
            const cadPart = cadVal != null ? ` $${cadVal.toFixed(2)} (CAD)` : "";
            return `+$${Math.abs(val).toFixed(2)} (${quoteCurrency.value}) locked${cadPart}`;
        }
        const cadVal = toAccountCurrency(val);
        const cadPart = cadVal != null ? ` $${cadVal.toFixed(2)} (CAD)` : "";
        return `$${val.toFixed(2)} (${quoteCurrency.value})${cadPart} at risk`;
    }
    if (riskAmount.value == null) return "—";
    const val = Math.max(0, riskAmount.value);
    const cadVal = toAccountCurrency(val);
    const cadPart = cadVal != null ? ` $${cadVal.toFixed(2)} (CAD)` : "";
    return `$${val.toFixed(2)} (${quoteCurrency.value})${cadPart}`;
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
    return v == null ? "—" : v.toFixed(5);
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

function directionPillClass(direction: string): string {
    switch (direction) {
        case "Long":
            return "bg-emerald-500/15 text-emerald-400";
        case "Short":
            return "bg-red-500/15 text-red-400";
        default:
            return "bg-muted text-muted-foreground";
    }
}

// Compute direction-aware PnL% (as a number where 2.5 means +2.5%) from a candle
// close price relative to the trade's entry. Long: (close - entry)/entry. Short:
// reverse. Sign reflects "is the trade in profit at this candle."
function pnlPctFromPrice(price: number): number {
    const entry = props.position.entry_price;
    const ratio = props.position.direction === "Long"
        ? (price - entry) / entry
        : (entry - price) / entry;
    return ratio * 100;
}

function initChart() {
    if (!sparklineEl.value) return;

    chart = createChart(sparklineEl.value, {
        layout: {
            background: { type: ColorType.Solid, color: "transparent" },
            textColor: "#a1a1aa",
            fontSize: 9,
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
            visible: true,
            borderVisible: false,
            entireTextOnly: true,
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
        lastValueVisible: true,
        priceFormat: {
            type: "custom",
            formatter: (value: number) => `${value >= 0 ? "+" : ""}${value.toFixed(2)}%`,
            minMove: 0.01,
        },
        // Extend the y-axis range to include all reference lines (SL, TP, TSL,
        // entry baseline) so they stay visible regardless of how far the line
        // itself has travelled.
        autoscaleInfoProvider: (baseImpl: () => AutoscaleInfo | null) => {
            const base = baseImpl();
            if (!base) return null;

            const refs: number[] = [0]; // entry baseline always included
            if (props.position.stop_loss_price != null) {
                refs.push(pnlPctFromPrice(props.position.stop_loss_price));
            }
            if (props.position.take_profit_price != null) {
                refs.push(pnlPctFromPrice(props.position.take_profit_price));
            }
            if (props.position.trailing_stop_loss_price != null) {
                refs.push(pnlPctFromPrice(props.position.trailing_stop_loss_price));
            }
            const minRef = Math.min(...refs);
            const maxRef = Math.max(...refs);

            return {
                priceRange: {
                    minValue: Math.min(base.priceRange.minValue, minRef),
                    maxValue: Math.max(base.priceRange.maxValue, maxRef),
                },
                margins: base.margins,
            };
        },
    });

    renderSparkline();
}

function clearPriceLines() {
    if (!series) return;
    priceLines.forEach((pl) => series?.removePriceLine(pl));
    priceLines = [];
}

function addPriceLine(opts: Parameters<ISeriesApi<"Line">["createPriceLine"]>[0]) {
    if (!series) return;
    priceLines.push(series.createPriceLine(opts));
}

function renderSparkline() {
    if (!chart || !series) return;

    // Y axis is PnL% from entry rather than raw price — normalized across
    // instruments and tells the story of the trade's journey, not just price.
    const points: LineData[] = props.position.sparkline.map((c) => ({
        time: Math.floor(new Date(c.timestamp).getTime() / 1000) as LineData["time"],
        value: pnlPctFromPrice(c.close),
    }));

    series.setData(points);

    // Clear previously-created reference lines before adding fresh ones —
    // otherwise they stack on top of each other on every poll cycle.
    clearPriceLines();

    // 0% baseline = entry price. Always visible.
    addPriceLine({
        price: 0,
        color: "#94a3b8",
        lineWidth: 1,
        lineStyle: LineStyle.Dotted,
        axisLabelVisible: true,
        title: "Entry",
    });

    if (props.position.stop_loss_price != null) {
        addPriceLine({
            price: pnlPctFromPrice(props.position.stop_loss_price),
            color: "#ef4444",
            lineWidth: 1,
            lineStyle: LineStyle.Dashed,
            axisLabelVisible: true,
            title: "SL",
        });
    }

    if (props.position.take_profit_price != null) {
        addPriceLine({
            price: pnlPctFromPrice(props.position.take_profit_price),
            color: "#22c55e",
            lineWidth: 1,
            lineStyle: LineStyle.Dashed,
            axisLabelVisible: true,
            title: "TP",
        });
    }

    if (props.position.trailing_stop_loss_price != null) {
        addPriceLine({
            price: pnlPctFromPrice(props.position.trailing_stop_loss_price),
            color: "#3b82f6",
            lineWidth: 1,
            lineStyle: LineStyle.Dashed,
            axisLabelVisible: true,
            title: "TSL",
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
