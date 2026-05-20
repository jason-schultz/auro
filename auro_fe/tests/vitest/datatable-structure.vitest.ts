import { mount } from "@vue/test-utils";
import { ref } from "vue";
import { describe, expect, it, vi } from "vitest";


async function mountPipelineTable() {
    vi.resetModules();

    const sortKey = ref("score");
    const sortDir = ref<"asc" | "desc">("desc");

    const row = {
        config_id: "cfg_1",
        instrument: "EUR_USD",
        strategy_type: "trend_following",
        granularity: "H1",
        evo_generation: 2,
        depth: 0,
        lineage_id: "lin_1",
        stage: "backtest",
        status: "passed",
        score: 1.23,
        failure_reason: null,
        source: "manual",
        evaluations: [],
        stats: { sharpe: 1.1, num_trades: 42, max_drawdown: 0.11 },
    };

    vi.doMock("@/composables/usePipeline", () => ({
        usePipeline: () => ({
            loading: ref(false),
            summary: ref({
                total: 1,
                running: 0,
                passed: 1,
                failed: 0,
                pending: 0,
                backtest: 1,
                walk_forward: 0,
                monte_carlo: 0,
            }),
            filterStrategy: ref(""),
            filterGranularity: ref(""),
            filterStatus: ref(""),
            filterSource: ref(""),
            sorted: ref([row]),
            sortKey,
            sortDir,
            childRank: vi.fn(() => 1),
            load: vi.fn(async () => undefined),
            toggleSort: vi.fn(),
            stageLabel: vi.fn(() => "Backtest"),
            sharpeStat: vi.fn(() => 1.1),
            tradesStat: vi.fn(() => 42),
            drawdownStat: vi.fn(() => 0.11),
            sharpeColor: vi.fn(() => "text-emerald-400"),
            scoreColor: vi.fn(() => "text-emerald-400"),
            fmt: vi.fn(() => "1.10"),
        }),
    }));

    const { default: Pipeline } = await import("@/views/Pipeline.vue");
    return mount(Pipeline);
}

async function mountStrategiesTable() {
    vi.resetModules();

    const sortKey = ref("instrument");
    const sortDir = ref<"asc" | "desc">("asc");

    const strategy = {
        id: "s1",
        instrument: "EUR_USD",
        strategy_type: "trend_following",
        granularity: "H1",
        parameters: {
            fast_period: 10,
            slow_period: 30,
            stop_loss: -0.02,
            take_profit: 0.03,
        },
        backtest_stats: {
            total_return: 0.12,
            win_rate: 0.55,
            sharpe_ratio: 1.2,
            max_drawdown: 0.08,
            num_trades: 40,
            avg_win: 0.03,
            avg_loss: -0.02,
        },
        oos_stats: {
            oos_sharpe: 0.7,
            oos_num_trades: 12,
        },
        live_stats: {
            num_trades: 8,
            win_rate: 0.5,
            avg_win: 0.02,
            avg_loss: -0.015,
        },
        source: "pipeline",
        pipeline_score: 0.9,
        enabled: true,
    };

    vi.doMock("@/composables/useStrategies", () => ({
        useStrategies: () => ({
            strategies: ref([strategy]),
            loading: ref(false),
            activeTab: ref("all"),
            strategyFilter: ref("all"),
            statusFilter: ref("all"),
            sortKey,
            sortDir,
            toggling: ref<string | null>(null),
            deleting: ref<string | null>(null),
            deleteConfirm: ref<string | null>(null),
            errorMessage: ref(""),
            marketTabs: [
                { id: "all", label: "All" },
                { id: "forex", label: "Forex" },
            ],
            strategyFilters: [
                { id: "all", label: "All" },
                { id: "trend_following", label: "Trend Following" },
            ],
            statusFilters: [
                { id: "all", label: "All" },
                { id: "enabled", label: "Active" },
            ],
            columns: [
                { key: "instrument", label: "Pair", sortable: true },
                { key: "strategy_type", label: "Type", sortable: true },
                { key: "granularity", label: "TF", sortable: false },
                { key: "params", label: "Parameters", sortable: false },
                { key: "total_return", label: "BT Return", sortable: true },
                { key: "win_rate", label: "BT Win%", sortable: true },
                { key: "sharpe_ratio", label: "IS Sharpe", sortable: true },
                { key: "oos_sharpe", label: "OOS Sharpe", sortable: true },
                { key: "max_drawdown", label: "DD", sortable: true },
                { key: "num_trades", label: "BT #", sortable: true },
                { key: "live_num_trades", label: "Live #", sortable: true },
                { key: "live_win_rate", label: "Live Win%", sortable: true },
                { key: "edge", label: "Edge", sortable: false },
                { key: "enabled", label: "Live", sortable: true },
            ],
            sortedStrategies: ref([strategy]),
            enabledCount: ref(1),
            tabCount: vi.fn(() => 1),
            toggleSort: vi.fn(),
            pct: vi.fn((v: number | null | undefined) => (v == null ? "-" : `${(v * 100).toFixed(2)}%`)),
            num: vi.fn((v: number | null | undefined, decimals = 2) =>
                v == null ? "-" : Number(v).toFixed(decimals)),
            winRateDeltaLabel: vi.fn(() => "+1.0"),
            winRateDeltaClass: vi.fn(() => "text-emerald-400"),
            edgeStatus: vi.fn(() => ({ label: "Holding", color: "bg-emerald-500/10 text-emerald-400" })),
            toggleStrategy: vi.fn(async () => undefined),
            deleteStrategy: vi.fn(async () => undefined),
            loadStrategies: vi.fn(async () => undefined),
        }),
    }));

    const { default: Strategies } = await import("@/views/Strategies.vue");
    return mount(Strategies);
}

describe("datatable structure contracts", () => {
    it("keeps Pipeline header/data counts aligned and sticky first column", async () => {
        const wrapper = await mountPipelineTable();

        const headers = wrapper.findAll("thead th");
        const firstRow = wrapper.find("tbody tr");
        const cells = firstRow.findAll("td");

        expect(headers.length).toBe(cells.length);
        expect(headers[0].classes()).toContain("sticky");
        expect(cells[0].classes()).toContain("sticky");
        expect(headers[6].classes()).toContain("text-right");
        expect(cells[6].classes()).toContain("tabular-nums");
    });

    it("keeps Strategies header/data counts aligned and sticky first column", async () => {
        const wrapper = await mountStrategiesTable();

        const headers = wrapper.findAll("thead th");
        const firstRow = wrapper.find("tbody tr");
        const cells = firstRow.findAll("td");

        expect(headers.length).toBe(cells.length);
        expect(headers[0].classes()).toContain("sticky");
        expect(cells[0].classes()).toContain("sticky");
        expect(headers[4].classes()).toContain("text-right");
        expect(cells[4].classes()).toContain("tabular-nums");

        const firstSortableHeader = headers[0];
        expect(firstSortableHeader.attributes("aria-sort")).toBe("ascending");
    });
});
