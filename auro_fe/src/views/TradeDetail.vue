<template>
    <main class="p-6">
        <div class="flex items-center justify-between mb-4">
            <div class="flex items-center gap-3">
                <router-link
                    to="/"
                    class="text-sm text-muted-foreground hover:text-foreground"
                >
                    ← Dashboard
                </router-link>
                <h2 class="text-lg font-semibold text-foreground">
                    Trade Detail
                </h2>
            </div>
        </div>

        <div v-if="loading" class="text-sm text-muted-foreground py-8 text-center">
            Loading trade...
        </div>

        <div v-else-if="error" class="fr-card p-4 text-sm text-red-400">
            {{ error }}
        </div>

        <div v-else-if="detail" class="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <!-- Trade card -->
            <div class="fr-card p-4">
                <div class="fr-section-label mb-4">Trade</div>

                <div class="space-y-3">
                    <div class="flex items-center gap-2">
                        <span
                            class="text-[10px] px-1.5 py-0.5 rounded font-medium"
                            :class="
                                detail.trade.status === 'closed'
                                    ? 'bg-muted text-muted-foreground'
                                    : detail.trade.direction === 'Long'
                                        ? 'bg-emerald-500/10 text-emerald-400'
                                        : 'bg-red-500/10 text-red-400'
                            "
                        >
                            {{ detail.trade.status === "closed" ? "Closed" : "Open" }}
                            {{ detail.trade.direction }}
                        </span>
                        <span class="text-base text-foreground">
                            {{ detail.trade.instrument.replace("_", "/") }}
                        </span>
                        <span class="font-mono text-sm text-muted-foreground">
                            {{ detail.trade.units }} units
                        </span>
                    </div>

                    <div class="grid grid-cols-2 gap-3">
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Entry
                            </div>
                            <div class="text-sm font-mono text-foreground">
                                ${{ formatPrice(detail.trade.entry_price) }}
                            </div>
                            <div class="text-[10px] text-muted-foreground mt-0.5 font-mono">
                                {{ formatTime(detail.trade.entry_time) }}
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Exit
                            </div>
                            <div class="text-sm font-mono text-foreground">
                                {{ exitDisplay }}
                            </div>
                            <div class="text-[10px] text-muted-foreground mt-0.5 font-mono">
                                {{ detail.trade.exit_time ? formatTime(detail.trade.exit_time) : "—" }}
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                P&L
                            </div>
                            <div
                                class="text-sm font-mono font-medium"
                                :class="pnlClass"
                            >
                                {{ pnlDisplay }}
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Duration
                            </div>
                            <div class="text-sm font-mono text-foreground">
                                {{ duration || "—" }}
                            </div>
                        </div>
                    </div>

                    <div v-if="detail.trade.entry_reason" class="bg-background rounded-md p-3">
                        <div class="text-[10px] text-muted-foreground mb-1">
                            Entry Reason
                        </div>
                        <div class="text-xs font-mono text-foreground break-words">
                            {{ detail.trade.entry_reason }}
                        </div>
                    </div>

                    <div v-if="detail.trade.exit_reason" class="bg-background rounded-md p-3">
                        <div class="text-[10px] text-muted-foreground mb-1">
                            Exit Reason
                        </div>
                        <div class="text-xs font-mono text-foreground break-words">
                            {{ detail.trade.exit_reason }}
                        </div>
                    </div>

                    <div
                        v-if="detail.trade.oanda_trade_id"
                        class="text-[10px] text-muted-foreground font-mono"
                    >
                        OANDA trade ID: {{ detail.trade.oanda_trade_id }}
                    </div>
                </div>
            </div>

            <!-- Strategy card -->
            <div class="fr-card p-4">
                <div class="fr-section-label mb-4">Strategy</div>

                <div v-if="!detail.strategy" class="text-sm text-muted-foreground py-4">
                    Strategy reference missing — strategy may have been deleted.
                </div>

                <div v-else class="space-y-3">
                    <div class="flex items-center gap-2">
                        <span class="text-base text-foreground">
                            {{ strategyTypeLabel }}
                        </span>
                        <span
                            class="text-[10px] px-1.5 py-0.5 rounded"
                            :class="
                                detail.strategy.enabled
                                    ? 'bg-emerald-500/10 text-emerald-400'
                                    : 'bg-muted text-muted-foreground'
                            "
                        >
                            {{ detail.strategy.enabled ? "Enabled" : "Disabled" }}
                        </span>
                    </div>

                    <div class="grid grid-cols-2 gap-3">
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Granularity
                            </div>
                            <div class="text-sm font-mono text-foreground">
                                {{ detail.strategy.granularity || "—" }}
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Max Position
                            </div>
                            <div class="text-sm font-mono text-foreground">
                                {{ detail.strategy.max_position_size || "—" }}
                            </div>
                        </div>
                    </div>

                    <div class="bg-background rounded-md p-3">
                        <div class="text-[10px] text-muted-foreground mb-2">
                            Parameters
                        </div>
                        <div class="space-y-1">
                            <div
                                v-for="(value, key) in detail.strategy.parameters"
                                :key="key"
                                class="flex justify-between text-xs font-mono"
                            >
                                <span class="text-muted-foreground">{{ key }}</span>
                                <span class="text-foreground">{{ formatParamValue(value) }}</span>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Live performance vs backtest -->
            <div class="fr-card p-4 lg:col-span-2">
                <div class="flex items-center justify-between mb-4">
                    <div class="fr-section-label mb-0 pb-0 border-b-0">
                        Live Performance for this Strategy
                    </div>
                    <span
                        v-if="edgeStatus"
                        class="text-[10px] px-2 py-0.5 rounded font-medium"
                        :class="edgeStatus.color"
                    >
                        {{ edgeStatus.label }}
                    </span>
                </div>

                <div
                    v-if="!detail.live_aggregate"
                    class="text-sm text-muted-foreground py-4"
                >
                    No closed live trades for this strategy yet.
                </div>

                <div v-else class="space-y-3">
                    <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                # Trades
                            </div>
                            <div class="text-sm font-mono text-foreground">
                                {{ detail.live_aggregate.num_trades }}
                                <span class="text-[10px] text-muted-foreground/60 ml-1">
                                    ({{ detail.live_aggregate.wins }}W / {{ detail.live_aggregate.losses }}L)
                                </span>
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Live Win Rate
                            </div>
                            <div class="text-sm font-mono text-foreground">
                                {{ formatPct(detail.live_aggregate.win_rate) }}
                            </div>
                            <div
                                v-if="winRateDelta !== null"
                                class="text-[10px] font-mono mt-0.5"
                                :class="deltaClass(winRateDelta)"
                            >
                                {{ formatDelta(winRateDelta) }} vs BT
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Live Total Return
                            </div>
                            <div
                                class="text-sm font-mono font-medium"
                                :class="
                                    detail.live_aggregate.total_return >= 0
                                        ? 'text-emerald-400'
                                        : 'text-red-400'
                                "
                            >
                                {{ formatPct(detail.live_aggregate.total_return) }}
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Live Expectancy
                            </div>
                            <div
                                class="text-sm font-mono font-medium"
                                :class="
                                    liveExpectancy >= 0
                                        ? 'text-emerald-400'
                                        : 'text-red-400'
                                "
                            >
                                {{ formatPct(liveExpectancy) }}
                            </div>
                            <div
                                v-if="expectancyDelta !== null"
                                class="text-[10px] font-mono mt-0.5"
                                :class="deltaClass(expectancyDelta)"
                            >
                                {{ formatDelta(expectancyDelta) }} vs BT
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Live Avg Win
                            </div>
                            <div class="text-sm font-mono text-emerald-400">
                                {{ formatPct(detail.live_aggregate.avg_win) }}
                            </div>
                            <div
                                v-if="avgWinDelta !== null"
                                class="text-[10px] font-mono mt-0.5"
                                :class="deltaClass(avgWinDelta)"
                            >
                                {{ formatDelta(avgWinDelta) }} vs BT
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Live Avg Loss
                            </div>
                            <div class="text-sm font-mono text-red-400">
                                {{ formatPct(detail.live_aggregate.avg_loss) }}
                            </div>
                            <div
                                v-if="avgLossDelta !== null"
                                class="text-[10px] font-mono mt-0.5"
                                :class="deltaClass(-avgLossDelta)"
                            >
                                {{ formatDelta(avgLossDelta) }} vs BT
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Backtest comparison card -->
            <div class="fr-card p-4 lg:col-span-2">
                <div class="fr-section-label mb-4">Source Backtest</div>

                <div v-if="!detail.backtest" class="text-sm text-muted-foreground py-4">
                    No source backtest linked. This strategy was not deployed from a backtest run.
                </div>

                <div v-else class="space-y-3">
                    <div class="text-sm text-foreground">
                        {{ detail.backtest.strategy_name || "Unnamed backtest" }}
                    </div>

                    <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Sharpe Ratio
                            </div>
                            <div
                                class="text-sm font-mono font-medium"
                                :class="sharpeClass(detail.backtest.sharpe_ratio)"
                            >
                                {{ formatStat(detail.backtest.sharpe_ratio, 2) }}
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Win Rate
                            </div>
                            <div class="text-sm font-mono text-foreground">
                                {{ formatPct(detail.backtest.win_rate) }}
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Total Return
                            </div>
                            <div
                                class="text-sm font-mono font-medium"
                                :class="
                                    (detail.backtest.total_return ?? 0) >= 0
                                        ? 'text-emerald-400'
                                        : 'text-red-400'
                                "
                            >
                                {{ formatPct(detail.backtest.total_return) }}
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Max Drawdown
                            </div>
                            <div class="text-sm font-mono text-red-400">
                                {{ formatPct(detail.backtest.max_drawdown) }}
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Avg Win
                            </div>
                            <div class="text-sm font-mono text-emerald-400">
                                {{ formatPct(detail.backtest.avg_win) }}
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Avg Loss
                            </div>
                            <div class="text-sm font-mono text-red-400">
                                {{ formatPct(detail.backtest.avg_loss) }}
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                # Trades
                            </div>
                            <div class="text-sm font-mono text-foreground">
                                {{ detail.backtest.num_trades ?? "—" }}
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Trade vs Avg
                            </div>
                            <div class="text-sm font-mono" :class="tradeVsAvgClass">
                                {{ tradeVsAvgLabel }}
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </main>
</template>

<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import { useRoute } from "vue-router";
import { api } from "@/services/api";

interface TradeData {
    id: string;
    oanda_trade_id: string | null;
    instrument: string;
    direction: string;
    units: string;
    entry_price: number | null;
    exit_price: number | null;
    entry_time: string;
    exit_time: string | null;
    pnl_percent: number | null;
    entry_reason: string | null;
    exit_reason: string | null;
    status: string;
}

interface StrategyData {
    id: string;
    strategy_type: string | null;
    parameters: Record<string, unknown> | null;
    granularity: string | null;
    enabled: boolean | null;
    max_position_size: string | null;
    backtest_run_id: string | null;
}

interface BacktestData {
    id: string;
    strategy_name: string | null;
    total_return: number | null;
    win_rate: number | null;
    sharpe_ratio: number | null;
    max_drawdown: number | null;
    num_trades: number | null;
    avg_win: number | null;
    avg_loss: number | null;
}

interface LiveAggregateData {
    num_trades: number;
    wins: number;
    losses: number;
    win_rate: number;
    total_return: number;
    avg_win: number;
    avg_loss: number;
}

interface DetailResponse {
    trade: TradeData;
    strategy: StrategyData | null;
    backtest: BacktestData | null;
    live_aggregate: LiveAggregateData | null;
}

const route = useRoute();
const detail = ref<DetailResponse | null>(null);
const loading = ref(true);
const error = ref<string | null>(null);

async function load(id: string) {
    loading.value = true;
    error.value = null;
    try {
        detail.value = await api.get<DetailResponse>(`/live/trades/${id}`);
    } catch (e) {
        error.value = `Failed to load trade: ${(e as Error).message}`;
    } finally {
        loading.value = false;
    }
}

onMounted(() => {
    const id = route.params.id as string;
    if (id) load(id);
});

watch(
    () => route.params.id,
    (newId) => {
        if (newId) load(newId as string);
    },
);

const exitDisplay = computed(() => {
    if (!detail.value) return "—";
    const exit = detail.value.trade.exit_price;
    if (exit == null || exit <= 0) return "—";
    return `$${formatPrice(exit)}`;
});

const pnlDisplay = computed(() => {
    if (!detail.value) return "—";
    const pnl = detail.value.trade.pnl_percent;
    if (pnl == null) return "—";
    const sign = pnl >= 0 ? "+" : "";
    return `${sign}${(pnl * 100).toFixed(2)}%`;
});

const pnlClass = computed(() => {
    if (!detail.value) return "text-foreground";
    const pnl = detail.value.trade.pnl_percent;
    if (pnl == null) return "text-foreground";
    return pnl >= 0 ? "text-emerald-400" : "text-red-400";
});

const duration = computed(() => {
    if (!detail.value) return null;
    const t = detail.value.trade;
    if (!t.exit_time) return null;
    const start = new Date(t.entry_time).getTime();
    const end = new Date(t.exit_time).getTime();
    if (isNaN(start) || isNaN(end) || end < start) return null;
    const min = Math.floor((end - start) / 60000);
    if (min < 60) return `${min}m`;
    const hr = Math.floor(min / 60);
    if (hr < 24) return `${hr}h`;
    const d = Math.floor(hr / 24);
    const remHr = hr - d * 24;
    return remHr === 0 ? `${d}d` : `${d}d ${remHr}h`;
});

const strategyTypeLabel = computed(() => {
    const t = detail.value?.strategy?.strategy_type;
    if (!t) return "—";
    if (t === "trend_following") return "Trend Following";
    if (t === "mean_reversion") return "Mean Reversion";
    return t;
});

const tradeVsAvgLabel = computed(() => {
    if (!detail.value?.backtest) return "—";
    const trade = detail.value.trade.pnl_percent;
    if (trade == null) return "—";
    const ref = trade >= 0 ? detail.value.backtest.avg_win : detail.value.backtest.avg_loss;
    if (ref == null || ref === 0) return "—";
    const ratio = trade / ref;
    return `${ratio.toFixed(2)}× avg ${trade >= 0 ? "win" : "loss"}`;
});

const tradeVsAvgClass = computed(() => {
    if (!detail.value?.backtest) return "text-foreground";
    const trade = detail.value.trade.pnl_percent;
    if (trade == null) return "text-foreground";
    return trade >= 0 ? "text-emerald-400" : "text-red-400";
});

function expectancy(
    winRate: number,
    avgWin: number,
    avgLoss: number,
): number {
    return winRate * avgWin + (1 - winRate) * avgLoss;
}

const liveExpectancy = computed(() => {
    const live = detail.value?.live_aggregate;
    if (!live) return 0;
    return expectancy(live.win_rate, live.avg_win, live.avg_loss);
});

const backtestExpectancy = computed(() => {
    const bt = detail.value?.backtest;
    if (!bt || bt.win_rate == null || bt.avg_win == null || bt.avg_loss == null)
        return null;
    return expectancy(bt.win_rate, bt.avg_win, bt.avg_loss);
});

const winRateDelta = computed(() => {
    const live = detail.value?.live_aggregate;
    const bt = detail.value?.backtest;
    if (!live || !bt || bt.win_rate == null) return null;
    return live.win_rate - bt.win_rate;
});

const expectancyDelta = computed(() => {
    const btExp = backtestExpectancy.value;
    if (btExp == null) return null;
    return liveExpectancy.value - btExp;
});

const avgWinDelta = computed(() => {
    const live = detail.value?.live_aggregate;
    const bt = detail.value?.backtest;
    if (!live || !bt || bt.avg_win == null) return null;
    return live.avg_win - bt.avg_win;
});

const avgLossDelta = computed(() => {
    const live = detail.value?.live_aggregate;
    const bt = detail.value?.backtest;
    if (!live || !bt || bt.avg_loss == null) return null;
    return live.avg_loss - bt.avg_loss;
});

const edgeStatus = computed(() => {
    const live = detail.value?.live_aggregate;
    const btExp = backtestExpectancy.value;
    if (!live || btExp == null) return null;

    if (live.num_trades < 5) {
        return {
            label: `Insufficient data (${live.num_trades}/5 trades)`,
            color: "bg-muted text-muted-foreground",
        };
    }

    const liveExp = liveExpectancy.value;

    // Both negative: strategy is broken regardless of vs-backtest delta
    if (liveExp <= 0 && btExp <= 0) {
        return {
            label: "Negative expectancy",
            color: "bg-red-500/10 text-red-400",
        };
    }

    if (btExp <= 0) {
        // Backtest expectancy was already negative; live is positive — that's actually good.
        return {
            label: "Live exceeds backtest",
            color: "bg-emerald-500/10 text-emerald-400",
        };
    }

    const ratio = liveExp / btExp;
    if (ratio >= 0.85) {
        return {
            label: "Edge holding",
            color: "bg-emerald-500/10 text-emerald-400",
        };
    }
    if (ratio >= 0.5) {
        return {
            label: "Edge degrading",
            color: "bg-amber-500/10 text-amber-400",
        };
    }
    return {
        label: "Edge broken",
        color: "bg-red-500/10 text-red-400",
    };
});

function deltaClass(delta: number | null): string {
    if (delta == null) return "text-muted-foreground";
    if (Math.abs(delta) < 0.001) return "text-muted-foreground";
    return delta >= 0 ? "text-emerald-400" : "text-red-400";
}

function formatDelta(delta: number | null): string {
    if (delta == null) return "—";
    const sign = delta >= 0 ? "+" : "";
    return `${sign}${(delta * 100).toFixed(2)}%`;
}

function formatPrice(price: number | null | undefined): string {
    if (price == null || price <= 0) return "—";
    const inst = detail.value?.trade.instrument || "";
    return price.toFixed(getDecimals(inst));
}

function getDecimals(instrument: string): number {
    if (instrument.endsWith("_JPY")) return 3;
    if (
        [
            "SPX500_USD",
            "NAS100_USD",
            "US30_USD",
            "UK100_GBP",
            "DE30_EUR",
            "EU50_EUR",
            "JP225_USD",
            "AU200_AUD",
        ].includes(instrument)
    )
        return 1;
    if (["XAU_USD", "XPT_USD", "XPD_USD"].includes(instrument)) return 2;
    if (instrument.startsWith("XAG_")) return 4;
    if (["BCO_USD", "WTICO_USD"].includes(instrument)) return 3;
    if (instrument === "NATGAS_USD" || instrument === "XCU_USD") return 4;
    return 5;
}

function formatTime(iso: string): string {
    if (!iso) return "—";
    const d = new Date(iso);
    return d.toLocaleString("en-CA", {
        month: "short",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
    });
}

function formatPct(value: number | null | undefined): string {
    if (value == null) return "—";
    const sign = value >= 0 ? "+" : "";
    return `${sign}${(value * 100).toFixed(2)}%`;
}

function formatStat(value: number | null | undefined, decimals: number): string {
    if (value == null) return "—";
    return value.toFixed(decimals);
}

function sharpeClass(value: number | null | undefined): string {
    if (value == null) return "text-foreground";
    if (value >= 1.0) return "text-emerald-400";
    if (value >= 0.5) return "text-amber-400";
    return "text-red-400";
}

function formatParamValue(value: unknown): string {
    if (value === null || value === undefined) return "—";
    if (typeof value === "number") {
        return Math.abs(value) < 1 && value !== 0
            ? value.toFixed(4)
            : value.toString();
    }
    return String(value);
}
</script>
