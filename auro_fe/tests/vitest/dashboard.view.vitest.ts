import { mount } from "@vue/test-utils";
import { nextTick, ref } from "vue";
import { describe, expect, it, vi } from "vitest";

async function mountDashboardView() {
    vi.resetModules();

    const account = ref<null | {
        balance: string;
        unrealized_pl: string;
        pl: string;
        margin_used: string;
        margin_available: string;
    }>(null);
    const positionsLoading = ref(true);
    const positions = ref<any[]>([]);
    const algoLoading = ref(false);
    const algoActivity = ref<any[]>([]);

    vi.doMock("@/composables/useDashboard", () => ({
        useDashboard: () => ({
            account,
            positions,
            positionsLoading,
            algoActivity,
            algoLoading,
            formatCurrency: (value: string) => `$${value}`,
            actionColor: () => "bg-muted text-muted-foreground",
            stateColor: () => "bg-muted text-muted-foreground",
            formatPrice: (value: number | null) => (value == null ? "—" : value.toFixed(5)),
            reasonShort: (value: string) => value,
            exitReasonColor: () => "text-foreground",
        }),
    }));

    const { default: Dashboard } = await import("@/views/Dashboard.vue");
    const wrapper = mount(Dashboard, {
        global: {
            stubs: {
                RouterLink: {
                    props: ["to"],
                    template: "<a :href='to'><slot /></a>",
                },
            },
        },
    });

    return {
        wrapper,
        account,
        positions,
        positionsLoading,
    };
}

describe("Dashboard view behavior", () => {
    it("shows loading state for positions table while positions are loading", async () => {
        const { wrapper } = await mountDashboardView();
        expect(wrapper.text()).toContain("Loading positions...");
    });

    it("renders an open position row after loading completes", async () => {
        const { wrapper, positions, positionsLoading, account } = await mountDashboardView();

        account.value = {
            balance: "10000",
            unrealized_pl: "10",
            pl: "5",
            margin_used: "100",
            margin_available: "9900",
        };
        positions.value = [
            {
                id: "p1",
                instrument: "EUR_USD",
                side: "Long",
                units: "1000",
                entry: "1.10000",
                current: "1.10100",
                stopLossState: "Initial",
                stopDisplay: null,
                targetDisplay: null,
                pl: 3.2,
            },
        ];
        positionsLoading.value = false;
        await nextTick();

        expect(wrapper.text()).toContain("EUR/USD");
        expect(wrapper.text()).toContain("Long");
        expect(wrapper.text()).toContain("+3.20");
        expect(wrapper.text()).toContain("Unrealized P&L");
        expect(wrapper.text()).toContain("Realized P&L");
        expect(wrapper.text()).toContain("Margin Used");
        expect(wrapper.text()).toContain("Margin Available");
    });
});
