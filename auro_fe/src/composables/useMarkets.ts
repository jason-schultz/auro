import { computed, onMounted, ref } from "vue";
import { useMarketStore } from "../stores/market";
import { api } from "../services/api";
import {
    getInstrumentCategory,
    MARKET_TABS_WITH_TSX,
    type MarketCategory,
} from "../lib/market";
import type { InstrumentsResponse, OandaInstrument } from "../types/market";

type Direction = "up" | "down" | "flat";

interface MarketListItem {
    instrument: string;
    bid: string | null;
    ask: string | null;
    spread: string | null;
    time: string | null;
    bidDirection: Direction;
    askDirection: Direction;
}

export function useMarkets() {
    const marketStore = useMarketStore();
    const connected = computed(() => marketStore.connected);

    const activeTab = ref("forex");
    const loading = ref(true);
    const allInstruments = ref<OandaInstrument[]>([]);

    const tabs = MARKET_TABS_WITH_TSX;

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
        if (day === 6) return true;
        if (day === 0 && hour < 17) return true;
        if (day === 5 && hour >= 17) return true;
        return false;
    });

    function categorize(instrument: OandaInstrument): string {
        return getInstrumentCategory(instrument.name);
    }

    const filteredInstruments = computed<MarketListItem[]>(() => {
        if (activeTab.value === "tsx") return [];
        const category = activeTab.value as MarketCategory;
        const instrumentNames = allInstruments.value
            .filter((inst) => categorize(inst) === category)
            .map((inst) => inst.name);

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

    async function loadInstruments() {
        loading.value = true;
        try {
            const data = await api.get<InstrumentsResponse>("/instruments");
            allInstruments.value = data.instruments;
        } catch (e) {
            console.error("Failed to load instruments:", e);
        } finally {
            loading.value = false;
        }
    }

    onMounted(loadInstruments);

    return {
        marketStore,
        connected,
        activeTab,
        loading,
        allInstruments,
        tabs,
        currentTabLabel,
        marketClosed,
        filteredInstruments,
        categorize,
        formatTime,
        loadInstruments,
    };
}
