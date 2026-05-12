import { mount } from "@vue/test-utils";
import { nextTick, ref } from "vue";
import { describe, expect, it, vi } from "vitest";

async function mountMarketsView() {
    vi.resetModules();

    const marketStore = {
        selectedInstrument: "EUR_USD",
        selectInstrument: vi.fn(),
    };

    const activeTab = ref("forex");
    const loading = ref(true);
    const filteredInstruments = ref<Array<{
        instrument: string;
        bid: string | null;
        ask: string | null;
        spread: string | null;
        time: string | null;
        bidDirection: "up" | "down" | "flat";
        askDirection: "up" | "down" | "flat";
    }>>([]);

    vi.doMock("@/composables/useMarkets", () => ({
        useMarkets: () => ({
            marketStore,
            connected: ref(true),
            activeTab,
            loading,
            tabs: [
                { id: "forex", label: "Forex" },
                { id: "tsx", label: "TSX" },
            ],
            currentTabLabel: ref("Forex"),
            marketClosed: ref(false),
            filteredInstruments,
            formatTime: (time: string) => time,
        }),
    }));

    const { default: Markets } = await import("@/views/Markets.vue");
    const wrapper = mount(Markets, {
        global: {
            stubs: {
                CandleChart: {
                    template: "<div data-test='candle-chart' />",
                },
            },
        },
    });

    return { wrapper, activeTab, loading, filteredInstruments };
}

describe("Markets view behavior", () => {
    it("shows loading state when no instruments are available and loading is true", async () => {
        const { wrapper } = await mountMarketsView();
        expect(wrapper.text()).toContain("Loading instruments...");
    });

    it("switches to TSX placeholder when TSX tab is clicked", async () => {
        const { wrapper, activeTab } = await mountMarketsView();

        await wrapper.get("button").trigger("click");
        const tsxButton = wrapper.findAll("button").find((b) => b.text().includes("TSX"));
        expect(tsxButton).toBeTruthy();

        await tsxButton!.trigger("click");
        await nextTick();

        expect(activeTab.value).toBe("tsx");
        expect(wrapper.text()).toContain("TSX equities - Wealthsimple manual tracking");
    });
});
