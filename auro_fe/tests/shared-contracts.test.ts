import { describe, expect, it } from "bun:test";
import {
    MARKET_TABS,
    MARKET_TABS_WITH_TSX,
    defaultDeployUnits,
    getInstrumentCategory,
} from "../src/lib/market";
import { formatStrategyConfigLabel, strategyTypeLabel } from "../src/lib/strategy";

describe("shared contracts", () => {
    it("keeps expected market tabs for shared segmented filters", () => {
        expect(MARKET_TABS.map((t) => t.id)).toEqual([
            "all",
            "forex",
            "metals",
            "commodities",
            "indices",
            "bonds",
        ]);
        expect(MARKET_TABS_WITH_TSX.map((t) => t.id)).toEqual([
            "forex",
            "metals",
            "commodities",
            "indices",
            "bonds",
            "tsx",
        ]);
    });

    it("keeps strategy type labels stable", () => {
        expect(strategyTypeLabel("trend_following")).toBe("Trend");
        expect(strategyTypeLabel("mean_reversion")).toBe("Mean Rev");
        expect(strategyTypeLabel("custom")).toBe("custom");
    });

    it("formats strategy config labels deterministically", () => {
        expect(
            formatStrategyConfigLabel(
                "trend_following",
                { fast_period: 10, slow_period: 30 },
                "H1",
            ),
        ).toBe("TF F10/S30 H1");

        expect(
            formatStrategyConfigLabel(
                "mean_reversion",
                { ma_period: 50, entry_threshold: 0.012 },
                "M15",
            ),
        ).toBe("MR MA50 1.2% M15");
    });

    it("retains key market classification and sizing contracts", () => {
        expect(getInstrumentCategory("NAS100_USD")).toBe("indices");
        expect(defaultDeployUnits("XAU_USD")).toBe("1");
    });
});
