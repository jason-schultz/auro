import { describe, expect, it } from "bun:test";
import { useBacktests } from "../src/composables/useBacktests";
import { makeBacktestRun } from "./factories";

describe("useBacktests", () => {
    it("sorts by sharpe descending by default", () => {
        const s = useBacktests();
        s.results.value = [
            makeBacktestRun({ id: "a", sharpe_ratio: 0.7 }),
            makeBacktestRun({ id: "b", sharpe_ratio: 1.2 }),
            makeBacktestRun({ id: "c", sharpe_ratio: 0.2 }),
        ];

        expect(s.sortedResults.value.map((r) => r.id)).toEqual(["b", "a", "c"]);
    });

    it("toggles sort direction for active key", () => {
        const s = useBacktests();
        expect(s.sortKey.value).toBe("sharpe_ratio");
        expect(s.sortDir.value).toBe("desc");

        s.toggleSort("sharpe_ratio");
        expect(s.sortDir.value).toBe("asc");

        s.toggleSort("sharpe_ratio");
        expect(s.sortDir.value).toBe("desc");
    });

    it("switches sort key and resets direction to desc", () => {
        const s = useBacktests();
        s.toggleSort("instrument");
        expect(s.sortKey.value).toBe("instrument");
        expect(s.sortDir.value).toBe("desc");
    });

    it("returns pipeline columns when source filter is pipeline", () => {
        const s = useBacktests();
        s.sourceFilter.value = "pipeline";
        expect(s.columns.value.map((c) => c.key)).toContain("oos_sharpe");
        expect(s.columns.value.map((c) => c.key)).toContain("granularity");
    });
});
