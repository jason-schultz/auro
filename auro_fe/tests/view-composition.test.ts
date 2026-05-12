import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

function readViewTemplate(fileName: string): string {
    const filePath = join(import.meta.dir, "..", "src", "views", fileName);
    return readFileSync(filePath, "utf8");
}

describe("view composition contracts", () => {
    it("keeps Backtests wired to shared shell components", () => {
        const backtests = readViewTemplate("Backtests.vue");

        expect(backtests).toContain("<ViewHeader title=\"Backtest Results\"");
        expect(backtests).toContain("<FilterToolbar");
        expect(backtests).toContain("<SegmentedFilterGroup");
        expect(backtests).toContain("<FilterSelect");
        expect(backtests).toContain("<FilterToolbarDivider");
        expect(backtests).toContain("<DataTableScaffold");
        expect(backtests).toContain("<StatusBadge");
    });

    it("keeps Markets wired to shared shell components", () => {
        const markets = readViewTemplate("Markets.vue");

        expect(markets).toContain("<ViewHeader title=\"Markets\"");
        expect(markets).toContain("<FilterToolbar");
        expect(markets).toContain("<SegmentedFilterGroup");
        expect(markets).toContain("<StateMessage");
    });

    it("keeps Pipeline wired to domain badge atoms", () => {
        const pipeline = readViewTemplate("Pipeline.vue");

        expect(pipeline).toContain("<StrategyTypeBadge");
        expect(pipeline).toContain("<StatusBadge");
    });

    it("keeps Strategies wired to strategy type badge atom", () => {
        const strategies = readViewTemplate("Strategies.vue");

        expect(strategies).toContain("<StrategyTypeBadge");
    });

    it("keeps Dashboard wired to shared stat value cards", () => {
        const dashboard = readViewTemplate("Dashboard.vue");

        expect(dashboard).toContain("<StatGrid");
    });

    it("keeps TradeDetail wired to shared stat grid component", () => {
        const tradeDetail = readViewTemplate("TradeDetail.vue");

        expect(tradeDetail).toContain("<StatGrid");
        expect(tradeDetail).toContain("<BadgePill");
    });

    it("keeps placeholder views aligned with shared shell components", () => {
        const journal = readViewTemplate("Journal.vue");
        const strategyEditor = readViewTemplate("StrategyEditor.vue");

        expect(journal).toContain("<ViewHeader");
        expect(journal).toContain("<DataCard");
        expect(strategyEditor).toContain("<ViewHeader");
        expect(strategyEditor).toContain("<DataCard");
    });
});
