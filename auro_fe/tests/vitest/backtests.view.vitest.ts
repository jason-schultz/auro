import { mount } from "@vue/test-utils";
import { nextTick, ref } from "vue";
import { describe, expect, it, vi } from "vitest";

async function mountBacktestsView() {
    vi.resetModules();

    const loadResultsCore = vi.fn(async () => undefined);
    const runGridSearchCore = vi.fn(async () => undefined);

    const sourceFilter = ref<"grid" | "pipeline">("grid");
    const statusFilter = ref("valid");
    const instrumentFilter = ref("");
    const strategyFilter = ref("all");
    const granularityFilter = ref("all");
    const sortKey = ref("sharpe_ratio");
    const sortDir = ref<"asc" | "desc">("desc");

    const resultRow = {
        id: "r1",
        strategy_name: "EUR_USD trend_following H1",
        strategy_type: "trend_following",
        instrument: "EUR_USD",
        granularity: "H1",
        parameters: {
            fast_period: 10,
            slow_period: 30,
            stop_loss: -0.02,
            take_profit: 0.03,
        },
        total_return: 0.1,
        win_rate: 0.52,
        sharpe_ratio: 1.1,
        max_drawdown: 0.08,
        num_trades: 50,
        avg_win: 0.7,
        avg_loss: 0.4,
        status: "valid",
        reason_flagged: null,
        execution_duration_ms: 10,
    };

    vi.doMock("@/composables/useBacktests", () => ({
        useBacktests: () => ({
            results: ref([resultRow]),
            loading: ref(false),
            running: ref(false),
            sourceFilter,
            statusFilter,
            instrumentFilter,
            sortKey,
            sortDir,
            strategyFilter,
            granularityFilter,
            runInstrument: ref("EUR_USD"),
            runTimeframe: ref("H1"),
            lastRunResult: ref(null),
            columns: ref([
                { key: "instrument", label: "Pair" },
                { key: "status", label: "Status" },
            ]),
            sortedResults: ref([resultRow]),
            toggleSort: vi.fn(),
            loadResults: loadResultsCore,
            runGridSearch: runGridSearchCore,
        }),
    }));

    const { default: Backtests } = await import("@/views/Backtests.vue");
    const wrapper = mount(Backtests);

    return { wrapper, sourceFilter, loadResultsCore };
}

describe("Backtests view behavior", () => {
    it("renders table status via shared StatusBadge", async () => {
        const { wrapper } = await mountBacktestsView();
        expect(wrapper.text()).toContain("valid");
    });

    it("switches source filter and reloads results", async () => {
        const { wrapper, sourceFilter, loadResultsCore } = await mountBacktestsView();

        const pipelineButton = wrapper.findAll("button").find((b) => b.text().includes("Pipeline"));
        expect(pipelineButton).toBeTruthy();

        await pipelineButton!.trigger("click");
        await nextTick();

        expect(sourceFilter.value).toBe("pipeline");
        expect(loadResultsCore).toHaveBeenCalled();
    });
});
