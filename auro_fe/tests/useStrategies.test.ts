import { describe, expect, it } from "bun:test";
import { useStrategies } from "../src/composables/useStrategies";
import { ApiError, api } from "../src/services/api";
import { makeBacktestStats, makeLiveStats, makeLiveStrategy } from "./factories";

describe("useStrategies", () => {
    it("filters by market tab and enabled status", () => {
        const s = useStrategies();
        s.strategies.value = [
            makeLiveStrategy({ id: "a", instrument: "EUR_USD", enabled: true }),
            makeLiveStrategy({ id: "b", instrument: "XAU_USD", enabled: false }),
            makeLiveStrategy({ id: "c", instrument: "NAS100_USD", enabled: true }),
        ];

        s.activeTab.value = "metals";
        s.statusFilter.value = "disabled";

        expect(s.filteredStrategies.value.map((x) => x.id)).toEqual(["b"]);
    });

    it("toggles sort direction and changes sort keys", () => {
        const s = useStrategies();
        expect(s.sortKey.value).toBe("instrument");
        expect(s.sortDir.value).toBe("asc");

        s.toggleSort("instrument");
        expect(s.sortDir.value).toBe("desc");

        s.toggleSort("total_return");
        expect(s.sortKey.value).toBe("total_return");
        expect(s.sortDir.value).toBe("desc");
    });

    it("sorts numeric metrics according to active sort", () => {
        const s = useStrategies();
        s.strategies.value = [
            makeLiveStrategy({ id: "a", backtest_stats: makeBacktestStats({ sharpe_ratio: 0.4 }) }),
            makeLiveStrategy({ id: "b", backtest_stats: makeBacktestStats({ sharpe_ratio: 1.6 }) }),
            makeLiveStrategy({ id: "c", backtest_stats: makeBacktestStats({ sharpe_ratio: 0.9 }) }),
        ];

        s.toggleSort("sharpe_ratio");
        expect(s.sortedStrategies.value.map((x) => x.id)).toEqual(["b", "c", "a"]);
    });

    it("reports holding edge when live expectancy is close to backtest", () => {
        const s = useStrategies();
        const strategy = makeLiveStrategy({
            backtest_stats: makeBacktestStats({
                total_return: 0.2,
                win_rate: 0.6,
                sharpe_ratio: 1.2,
                max_drawdown: 0.1,
                num_trades: 40,
                avg_win: 1,
                avg_loss: 0.5,
            }),
            live_stats: makeLiveStats({
                num_trades: 12,
                wins: 7,
                losses: 5,
                win_rate: 0.58,
                total_return: 0.05,
                avg_win: 0.95,
                avg_loss: 0.52,
            }),
        });

        expect(s.edgeStatus(strategy).label).toBe("Holding");
    });

    it("sets error message and clears toggling when toggle fails", async () => {
        const s = useStrategies();
        const strategy = makeLiveStrategy({ id: "err-1", enabled: true });
        const originalPost = api.post;
        const originalConsoleError = console.error;

        api.post = async () => {
            throw new ApiError(500, { error: "toggle down" }, "API error: 500 toggle down");
        };
        console.error = () => { };

        try {
            await s.toggleStrategy(strategy);
            expect(s.toggling.value).toBeNull();
            expect(s.errorMessage.value).toContain("toggle down");
            expect(strategy.enabled).toBe(true);
        } finally {
            api.post = originalPost;
            console.error = originalConsoleError;
        }
    });

    it("sets error message and clears deleting when delete fails", async () => {
        const s = useStrategies();
        const strategy = makeLiveStrategy({ id: "del-1" });
        s.strategies.value = [strategy];

        const originalDelete = api.delete;
        const originalConsoleError = console.error;

        api.delete = async () => {
            throw new ApiError(500, { error: "delete down" }, "API error: 500 delete down");
        };
        console.error = () => { };

        try {
            await s.deleteStrategy(strategy);
            expect(s.deleting.value).toBeNull();
            expect(s.errorMessage.value).toContain("delete down");
            expect(s.strategies.value).toHaveLength(1);
            expect(s.strategies.value[0]?.id).toBe("del-1");
        } finally {
            api.delete = originalDelete;
            console.error = originalConsoleError;
        }
    });

    it("sets error message and clears loading when load fails", async () => {
        const s = useStrategies();
        const originalGet = api.get;
        const originalConsoleError = console.error;

        api.get = async () => {
            throw new ApiError(503, { error: "service unavailable" }, "API error: 503 service unavailable");
        };
        console.error = () => { };

        try {
            await s.loadStrategies();
            expect(s.loading.value).toBe(false);
            expect(s.errorMessage.value).toContain("service unavailable");
            expect(s.strategies.value).toEqual([]);
        } finally {
            api.get = originalGet;
            console.error = originalConsoleError;
        }
    });
});
