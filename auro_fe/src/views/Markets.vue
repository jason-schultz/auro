<template>
    <main class="p-6 h-[calc(100vh-57px)] flex flex-col">
        <!-- Market tabs -->
        <div class="flex items-center gap-1 mb-4">
            <button
                v-for="tab in tabs"
                :key="tab.id"
                class="px-3 py-1.5 text-sm rounded transition-colors"
                :class="
                    activeTab === tab.id
                        ? 'bg-primary/10 text-primary'
                        : 'text-muted-foreground hover:text-foreground'
                "
                @click="activeTab = tab.id"
            >
                {{ tab.label }}
            </button>
        </div>

        <div v-if="marketClosed" class="fr-card p-3 mb-4">
            <div class="text-sm text-muted-foreground text-center">
                Forex market is currently closed. Live prices will resume Sunday
                5pm ET.
            </div>
        </div>

        <!-- TSX placeholder -->
        <div v-if="activeTab === 'tsx'" class="flex-1">
            <div class="fr-card p-12 text-muted-foreground text-center text-sm">
                <div class="mb-2">
                    TSX equities — Wealthsimple manual tracking
                </div>
                <div class="text-[10px] text-muted-foreground/50">
                    Data source TBD. Will pull from Yahoo Finance or Alpha
                    Vantage.
                </div>
            </div>
        </div>

        <!-- OANDA markets -->
        <div
            v-else
            class="grid grid-cols-1 lg:grid-cols-4 gap-4 flex-1 min-h-0"
        >
            <aside class="lg:col-span-1 overflow-y-auto">
                <div class="flex items-center justify-between mb-3">
                    <div class="fr-section-label mb-0 pb-0 border-b-0">
                        {{ currentTabLabel }}
                    </div>
                    <div class="flex items-center gap-2">
                        <span
                            class="h-1.5 w-1.5 rounded-full"
                            :class="
                                connected
                                    ? 'bg-emerald-500 animate-pulse'
                                    : 'bg-red-500'
                            "
                        />
                        <span class="text-[10px] text-muted-foreground">
                            {{ connected ? "Connected" : "Disconnected" }}
                        </span>
                    </div>
                </div>

                <div
                    v-if="filteredInstruments.length === 0"
                    class="text-sm text-muted-foreground py-8 text-center"
                >
                    {{
                        loading
                            ? "Loading instruments..."
                            : "No instruments available"
                    }}
                </div>

                <div v-else class="grid gap-2">
                    <div
                        v-for="item in filteredInstruments"
                        :key="item.instrument"
                        class="fr-card-interactive p-3 cursor-pointer"
                        :class="
                            marketStore.selectedInstrument === item.instrument
                                ? 'fr-card-selected'
                                : ''
                        "
                        @click="marketStore.selectInstrument(item.instrument)"
                    >
                        <div class="flex items-center justify-between mb-2">
                            <span class="text-sm font-semibold text-foreground">
                                {{ item.instrument.replace("_", "/") }}
                            </span>
                            <span
                                v-if="item.time"
                                class="text-[10px] text-muted-foreground/50 font-mono"
                            >
                                {{ formatTime(item.time) }}
                            </span>
                        </div>

                        <div
                            v-if="item.bid"
                            class="grid grid-cols-3 gap-2 text-xs"
                        >
                            <div>
                                <div class="text-muted-foreground mb-0.5">
                                    Bid
                                </div>
                                <div
                                    class="font-mono font-medium transition-colors duration-300"
                                    :class="{
                                        'text-emerald-400':
                                            item.bidDirection === 'up',
                                        'text-red-400':
                                            item.bidDirection === 'down',
                                        'text-foreground':
                                            item.bidDirection === 'flat',
                                    }"
                                >
                                    {{ item.bid }}
                                </div>
                            </div>
                            <div>
                                <div class="text-muted-foreground mb-0.5">
                                    Ask
                                </div>
                                <div
                                    class="font-mono font-medium transition-colors duration-300"
                                    :class="{
                                        'text-emerald-400':
                                            item.askDirection === 'up',
                                        'text-red-400':
                                            item.askDirection === 'down',
                                        'text-foreground':
                                            item.askDirection === 'flat',
                                    }"
                                >
                                    {{ item.ask }}
                                </div>
                            </div>
                            <div>
                                <div class="text-muted-foreground mb-0.5">
                                    Spread
                                </div>
                                <div
                                    class="font-mono font-medium text-muted-foreground"
                                >
                                    {{ item.spread }}
                                </div>
                            </div>
                        </div>

                        <div v-else class="text-xs text-muted-foreground">
                            Waiting for data...
                        </div>
                    </div>
                </div>
            </aside>

            <div class="lg:col-span-3 fr-card overflow-hidden">
                <CandleChart />
            </div>
        </div>
    </main>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from "vue";
import { useMarketStore } from "@/stores/market";
import { api } from "@/services/api";
import CandleChart from "@/components/CandleChart.vue";

const marketStore = useMarketStore();
const connected = computed(() => marketStore.connected);

const activeTab = ref("forex");
const loading = ref(true);

interface OandaInstrument {
    name: string;
    displayName: string;
    type: string;
}

const allInstruments = ref<OandaInstrument[]>([]);

const tabs = [
    { id: "forex", label: "Forex" },
    { id: "metals", label: "Metals" },
    { id: "commodities", label: "Commodities" },
    { id: "indices", label: "Indices" },
    { id: "bonds", label: "Bonds" },
    { id: "tsx", label: "TSX" },
];

const currentTabLabel = computed(() => {
    return tabs.find((t) => t.id === activeTab.value)?.label ?? "";
});

const marketClosed = computed(() => {
    const now = new Date();
    const et = new Date(
        now.toLocaleString("en-US", { timeZone: "America/New_York" }),
    );
    const day = et.getDay();
    const hour = et.getHours();
    if (day === 6) return true; // Saturday
    if (day === 0 && hour < 17) return true; // Sunday before 5pm ET
    if (day === 5 && hour >= 17) return true; // Friday after 5pm ET
    return false;
});

// Map OANDA instrument types to our tab categories
function categorize(instrument: OandaInstrument): string {
    const name = instrument.name;
    const type = instrument.type;

    if (type === "METAL") return "metals";
    if (type === "CURRENCY") return "forex";

    // CFD type needs manual splitting
    // Bonds
    if (name.includes("USB") || name.includes("10YB")) return "bonds";

    // Commodities
    if (
        name.startsWith("WTICO") ||
        name.startsWith("BCO") ||
        name.startsWith("NATGAS") ||
        name.startsWith("CORN") ||
        name.startsWith("SOYBN") ||
        name.startsWith("WHEAT") ||
        name.startsWith("SUGAR") ||
        name.startsWith("XCU") ||
        name.startsWith("XPT") ||
        name.startsWith("XPD")
    ) {
        return "commodities";
    }

    // Everything else CFD is an index
    return "indices";
}

const filteredInstruments = computed(() => {
    const category = activeTab.value;
    const instrumentNames = allInstruments.value
        .filter((inst) => categorize(inst) === category)
        .map((inst) => inst.name);

    // Merge with live price data from the store
    return instrumentNames.map((name) => {
        const tick = marketStore.prices[name];
        if (tick) {
            const bid = parseFloat(tick.bid);
            const ask = parseFloat(tick.ask);
            const spread = ask - bid;

            return {
                instrument: name,
                bid: tick.bid,
                ask: tick.ask,
                spread: spread.toFixed(name.includes("JPY") ? 3 : 5),
                time: tick.time,
                bidDirection: tick.prevBid
                    ? Math.abs(bid - parseFloat(tick.prevBid)) > 0.00001
                        ? bid > parseFloat(tick.prevBid)
                            ? "up"
                            : "down"
                        : "flat"
                    : "flat",
                askDirection: tick.prevAsk
                    ? Math.abs(ask - parseFloat(tick.prevAsk)) > 0.00001
                        ? ask > parseFloat(tick.prevAsk)
                            ? "up"
                            : "down"
                        : "flat"
                    : "flat",
            };
        }

        return {
            instrument: name,
            bid: null,
            ask: null,
            spread: null,
            time: null,
            bidDirection: "flat",
            askDirection: "flat",
        };
    });
});

function formatTime(time: string): string {
    try {
        return new Date(time).toLocaleTimeString();
    } catch {
        return time;
    }
}

onMounted(async () => {
    try {
        const data = await api.get<{
            instruments: OandaInstrument[];
            count: number;
        }>("/instruments");
        allInstruments.value = data.instruments;
    } catch (e) {
        console.error("Failed to load instruments:", e);
    } finally {
        loading.value = false;
    }
});
</script>
