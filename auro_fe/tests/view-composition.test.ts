import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

function readViewTemplate(fileName: string): string {
    const filePath = join(import.meta.dir, "..", "src", "views", fileName);
    return readFileSync(filePath, "utf8");
}

describe("view composition contracts", () => {
    it("keeps Pipeline wired to domain badge atoms", () => {
        const pipeline = readViewTemplate("Pipeline.vue");

        expect(pipeline).toContain("<StrategyTypeBadge");
        expect(pipeline).toContain("<StatusBadge");
    });

    it("keeps Strategies wired to strategy type badge atom", () => {
        const strategies = readViewTemplate("Strategies.vue");

        expect(strategies).toContain("<StrategyTypeBadge");
    });

    it("keeps Dashboard wired to risk and signal panels", () => {
        const dashboard = readViewTemplate("Dashboard.vue");

        expect(dashboard).toContain("<SignalFeedPanel");
        expect(dashboard).toContain("<RegimeHeatmapPanel");
        expect(dashboard).toContain("<OpenPositionsPanel");
    });

    it("keeps TradeDetail wired to shared stat grid component", () => {
        const tradeDetail = readViewTemplate("TradeDetail.vue");

        expect(tradeDetail).toContain("<StatGrid");
        expect(tradeDetail).toContain("<BadgePill");
    });

    it("keeps Journal wired to shared shell components", () => {
        const journal = readViewTemplate("Journal.vue");

        expect(journal).toContain("<ViewHeader");
        expect(journal).toContain("<FilterToolbar");
        expect(journal).toContain("<SegmentedFilterGroup");
        expect(journal).toContain("<DataTableScaffold");
    });

    it("keeps placeholder views aligned with shared shell components", () => {
        const strategyEditor = readViewTemplate("StrategyEditor.vue");

        expect(strategyEditor).toContain("<ViewHeader");
        expect(strategyEditor).toContain("<DataCard");
    });
});
