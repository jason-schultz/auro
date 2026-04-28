<template>
    <main class="p-6">
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
            <!-- Account Summary -->
            <div class="lg:col-span-1 fr-card p-4">
                <div class="fr-section-label mb-4">Account Summary</div>

                <div
                    v-if="!account"
                    class="text-sm text-muted-foreground py-4 text-center"
                >
                    Loading account...
                </div>

                <div v-else class="space-y-3">
                    <div class="text-center mb-4">
                        <div
                            class="text-[10px] uppercase tracking-wider text-muted-foreground mb-1"
                        >
                            Net Asset Value
                        </div>
                        <div
                            class="text-2xl font-mono font-semibold text-foreground"
                        >
                            {{ formatCurrency(account.balance) }}
                        </div>
                    </div>

                    <div class="grid grid-cols-2 gap-3">
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Unrealized P&L
                            </div>
                            <div
                                class="text-sm font-mono font-medium"
                                :class="
                                    parseFloat(account.unrealized_pl) >= 0
                                        ? 'text-emerald-400'
                                        : 'text-red-400'
                                "
                            >
                                {{ formatCurrency(account.unrealized_pl) }}
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Realized P&L
                            </div>
                            <div
                                class="text-sm font-mono font-medium"
                                :class="
                                    parseFloat(account.pl) >= 0
                                        ? 'text-emerald-400'
                                        : 'text-red-400'
                                "
                            >
                                {{ formatCurrency(account.pl) }}
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Margin Used
                            </div>
                            <div
                                class="text-sm font-mono font-medium text-foreground"
                            >
                                {{ formatCurrency(account.margin_used) }}
                            </div>
                        </div>
                        <div class="bg-background rounded-md p-3">
                            <div class="text-[10px] text-muted-foreground mb-1">
                                Margin Available
                            </div>
                            <div
                                class="text-sm font-mono font-medium text-foreground"
                            >
                                {{ formatCurrency(account.margin_available) }}
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Open Positions -->
            <div class="lg:col-span-2 fr-card p-4">
                <div class="flex items-center justify-between mb-4">
                    <div class="fr-section-label mb-0 pb-0 border-b-0">
                        Open Positions
                    </div>
                    <span class="text-[10px] text-muted-foreground font-mono">
                        {{ positions.length }} open
                    </span>
                </div>

                <div
                    v-if="positionsLoading"
                    class="text-sm text-muted-foreground py-8 text-center"
                >
                    Loading positions...
                </div>

                <div
                    v-else-if="positions.length === 0"
                    class="text-sm text-muted-foreground py-8 text-center"
                >
                    No open positions
                </div>

                <table v-else class="w-full text-sm">
                    <thead>
                        <tr class="text-muted-foreground">
                            <th
                                class="text-left pb-2 text-[10px] font-medium uppercase tracking-wider"
                            >
                                Instrument
                            </th>
                            <th
                                class="text-right pb-2 text-[10px] font-medium uppercase tracking-wider"
                            >
                                Side
                            </th>
                            <th
                                class="text-right pb-2 text-[10px] font-medium uppercase tracking-wider"
                            >
                                Units
                            </th>
                            <th
                                class="text-right pb-2 text-[10px] font-medium uppercase tracking-wider"
                            >
                                Entry
                            </th>
                            <th
                                class="text-right pb-2 text-[10px] font-medium uppercase tracking-wider"
                            >
                                Current
                            </th>
                            <th
                                class="text-right pb-2 text-[10px] font-medium uppercase tracking-wider"
                            >
                                P&L
                            </th>
                        </tr>
                    </thead>
                    <tbody>
                        <tr
                            v-for="pos in positions"
                            :key="pos.id"
                            class="border-b border-border"
                        >
                            <td class="py-2 text-foreground">
                                {{ pos.instrument.replace("_", "/") }}
                            </td>
                            <td class="py-2 text-right">
                                <span
                                    class="text-[10px] px-1.5 py-0.5 rounded font-medium"
                                    :class="
                                        pos.side === 'Long'
                                            ? 'bg-emerald-500/10 text-emerald-400'
                                            : 'bg-red-500/10 text-red-400'
                                    "
                                    >{{ pos.side }}</span
                                >
                            </td>
                            <td
                                class="py-2 text-right font-mono text-foreground"
                            >
                                {{ pos.units }}
                            </td>
                            <td
                                class="py-2 text-right font-mono text-muted-foreground"
                            >
                                ${{ pos.entry }}
                            </td>
                            <td
                                class="py-2 text-right font-mono text-foreground"
                            >
                                ${{ pos.current }}
                            </td>
                            <td
                                class="py-2 text-right font-mono font-medium"
                                :class="
                                    pos.pl >= 0
                                        ? 'text-emerald-400'
                                        : 'text-red-400'
                                "
                            >
                                {{ pos.pl >= 0 ? "+" : ""
                                }}{{ pos.pl.toFixed(2) }}
                            </td>
                        </tr>
                    </tbody>
                </table>
            </div>

            <!-- Algo Activity -->
            <div class="lg:col-span-2 fr-card p-4">
                <div class="flex items-center justify-between mb-4">
                    <div class="fr-section-label mb-0 pb-0 border-b-0">
                        Algo Activity
                    </div>
                    <span class="text-[10px] text-muted-foreground font-mono">
                        Last {{ algoActivity.length }} trades
                    </span>
                </div>

                <div
                    v-if="algoLoading"
                    class="text-sm text-muted-foreground py-8 text-center"
                >
                    Loading activity...
                </div>

                <div
                    v-else-if="algoActivity.length === 0"
                    class="text-sm text-muted-foreground py-8 text-center"
                >
                    No algo activity yet — waiting for signals
                </div>

                <div v-else class="space-y-2">
                    <div
                        v-for="entry in algoActivity"
                        :key="entry.id"
                        class="bg-background rounded-md p-3"
                    >
                        <div class="flex items-center justify-between mb-1.5">
                            <div class="flex items-center gap-2">
                                <span
                                    class="text-[10px] px-1.5 py-0.5 rounded font-medium"
                                    :class="actionColor(entry.action)"
                                    >{{ entry.action }}</span
                                >
                                <span class="text-sm text-foreground">
                                    {{ entry.instrument.replace("_", "/") }}
                                </span>
                                <span
                                    class="font-mono text-xs text-muted-foreground"
                                >
                                    {{ entry.units }} units
                                </span>
                            </div>
                            <span
                                class="text-[10px] text-muted-foreground font-mono"
                            >
                                {{ entry.time }}
                            </span>
                        </div>
                        <div
                            v-if="entry.reason"
                            class="text-xs text-muted-foreground"
                        >
                            {{ entry.reason }}
                        </div>
                        <div class="flex items-center gap-2 mt-1.5">
                            <span
                                class="text-[10px] text-primary/60 bg-primary/8 px-1.5 py-0.5 rounded"
                            >
                                {{ entry.direction }} · {{ entry.status }}
                            </span>
                            <span
                                v-if="entry.pnl != null"
                                class="text-[10px] font-mono font-medium"
                                :class="
                                    entry.pnl >= 0
                                        ? 'text-emerald-400'
                                        : 'text-red-400'
                                "
                            >
                                {{ entry.pnl >= 0 ? "+" : ""
                                }}{{ (entry.pnl * 100).toFixed(2) }}%
                            </span>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Manual Opportunities -->
            <div class="lg:col-span-1 fr-card p-4">
                <div class="fr-section-label mb-4">Manual Opportunities</div>

                <div class="text-sm text-muted-foreground py-8 text-center">
                    Coming soon — Wealthsimple / TSX signals
                </div>
            </div>

            <!-- Market News -->
            <div class="lg:col-span-3 fr-card p-4">
                <div class="fr-section-label mb-4">Market News</div>

                <div class="text-sm text-muted-foreground py-8 text-center">
                    Coming soon — news feed integration
                </div>
            </div>
        </div>
    </main>
</template>

<script setup lang="ts">
import { computed, ref, onMounted, onUnmounted, watch } from "vue";
import { useMarketStore } from "@/stores/market";
import { api } from "@/services/api";

interface AccountData {
    id: string;
    currency: string;
    balance: string;
    unrealized_pl: string;
    pl: string;
    open_trade_count: number;
    open_position_count: number;
    margin_used: string;
    margin_available: string;
}

interface Position {
    id: string;
    instrument: string;
    side: string;
    units: string;
    entry: string;
    current: string;
    pl: number;
}

interface AlgoEntry {
    id: string;
    instrument: string;
    direction: string;
    units: string;
    action: string;
    reason: string;
    status: string;
    time: string;
    pnl: number | null;
}

const marketStore = useMarketStore();
const connected = computed(() => marketStore.connected);

const account = ref<AccountData | null>(null);
const positions = ref<Position[]>([]);
const positionsLoading = ref(true);
const algoActivity = ref<AlgoEntry[]>([]);
const algoLoading = ref(true);
const lastKnownPrices = ref<string, number>({});

let refreshInterval: ReturnType<typeof setInterval> | null = null;

watch(
    () => marketStore.prices,
    (prices) => {
        for (const [instrument, price] of Object.entries(prices)) {
            if (price?.ask) {
                lastKnownPrices.value[instrument] = parseFloat(price.ask);
            }
        }
    },
    { deep: true },
);

function getLastKnownPrice(instrument: string): number | null {
    return lastKnownPrices.value[instrument] ?? null;
}

function formatCurrency(value: string): string {
    const num = parseFloat(value);
    return new Intl.NumberFormat("en-CA", {
        style: "currency",
        currency: "CAD",
        minimumFractionDigits: 2,
    }).format(num);
}

function actionColor(action: string): string {
    if (action.startsWith("Opened") && action.includes("Long")) {
        return "bg-emerald-500/10 text-emerald-400";
    }
    if (action.startsWith("Opened") && action.includes("Short")) {
        return "bg-red-500/10 text-red-400";
    }
    if (action.startsWith("Closed")) {
        return "bg-muted text-muted-foreground";
    }
    return "bg-secondary text-muted-foreground";
}

function timeAgo(dateStr: string): string {
    const now = new Date();
    const then = new Date(dateStr);
    const diffMs = now.getTime() - then.getTime();
    const diffMin = Math.floor(diffMs / 60000);

    if (diffMin < 1) return "just now";
    if (diffMin < 60) return `${diffMin}m ago`;

    const diffHr = Math.floor(diffMin / 60);
    if (diffHr < 24) return `${diffHr}h ago`;

    const diffDays = Math.floor(diffHr / 24);
    return `${diffDays}d ago`;
}

async function loadAccount() {
    try {
        account.value = await api.get<AccountData>("/account");
    } catch (e) {
        console.error("Failed to load account:", e);
    }
}

async function loadPositions() {
    try {
        const data = await api.get<{ trades: any[] }>("/open-trades");
        positions.value = (data.trades || []).map((t: any) => {
            const livePrice = marketStore.prices[t.instrument];
            const currentPrice = livePrice
                ? parseFloat(livePrice.ask)
                : getLastKnownPrice(t.instrument);

            const entryPrice = parseFloat(t.price || "0");
            const units = parseFloat(t.currentUnits || t.initialUnits || "0");
            const pl = parseFloat(t.unrealizedPL || "0");
            const isLong = units > 0;
            return {
                id: t.id,
                instrument: t.instrument,
                side: isLong ? "Long" : "Short",
                units: Math.abs(units).toString(),
                entry: entryPrice || "—",
                current: currentPrice ? currentPrice.toFixed(2) : "-",
                pl: pl,
            };
        });
    } catch (e) {
        console.error("Failed to load positions:", e);
    } finally {
        positionsLoading.value = false;
    }
}

async function loadAlgoActivity() {
    try {
        const data = await api.get<{ trades: any[] }>("/live/trades?limit=20");
        algoActivity.value = (data.trades || []).map((t: any) => {
            const isClosed = t.status === "closed";
            const action = isClosed
                ? `Closed ${t.direction}`
                : `Opened ${t.direction}`;

            return {
                id: t.id,
                instrument: t.instrument,
                direction: t.direction,
                units: t.units,
                action,
                reason: t.entry_reason || t.exit_reason || "",
                status: t.status,
                time: timeAgo(
                    isClosed && t.exit_time ? t.exit_time : t.entry_time,
                ),
                pnl: t.pnl_percent != null ? t.pnl_percent : null,
            };
        });
    } catch (e) {
        console.error("Failed to load algo activity:", e);
    } finally {
        algoLoading.value = false;
    }
}

async function refreshAll() {
    await Promise.all([loadAccount(), loadPositions(), loadAlgoActivity()]);
}

onMounted(() => {
    refreshAll();
    refreshInterval = setInterval(refreshAll, 15000);
});

onUnmounted(() => {
    if (refreshInterval) clearInterval(refreshInterval);
});
</script>
