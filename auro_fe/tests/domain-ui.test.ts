import { describe, expect, it } from "bun:test";
import {
    statusBadgeClass,
    strategyEnabledBadgeClass,
    tradeDirectionBadgeClass,
    tradeExitReasonBadgeClass,
    strategyTypeBadgeClass,
    strategyTypeBadgeLabel,
} from "../src/lib/domain-ui";

describe("domain ui helpers", () => {
    it("maps status values to consistent badge classes", () => {
        expect(statusBadgeClass("valid")).toContain("text-emerald-400");
        expect(statusBadgeClass("passed")).toContain("text-emerald-400");
        expect(statusBadgeClass("verify")).toContain("text-primary");
        expect(statusBadgeClass("running")).toContain("text-primary");
        expect(statusBadgeClass("failed")).toContain("text-red-400");
        expect(statusBadgeClass("pending")).toContain("text-muted-foreground");
    });

    it("maps strategy type badge labels and classes", () => {
        expect(strategyTypeBadgeLabel("mean_reversion")).toBe("Mean Rev");
        expect(strategyTypeBadgeLabel("trend_following")).toBe("Trend");
        expect(strategyTypeBadgeClass("mean_reversion")).toContain("text-blue-400");
        expect(strategyTypeBadgeClass("trend_following")).toContain("text-violet-400");
    });

    it("maps trade exit reasons to stable badge classes", () => {
        expect(tradeExitReasonBadgeClass("TakeProfit")).toContain("text-emerald-400");
        expect(tradeExitReasonBadgeClass("StopLoss")).toContain("text-red-400");
        expect(tradeExitReasonBadgeClass("TrendReversal")).toContain("text-muted-foreground");
    });

    it("maps trade direction and strategy enabled badge classes", () => {
        expect(tradeDirectionBadgeClass("closed", "Long")).toContain("text-muted-foreground");
        expect(tradeDirectionBadgeClass("open", "Long")).toContain("text-emerald-400");
        expect(tradeDirectionBadgeClass("open", "Short")).toContain("text-red-400");
        expect(strategyEnabledBadgeClass(true)).toContain("text-emerald-400");
        expect(strategyEnabledBadgeClass(false)).toContain("text-muted-foreground");
    });
});
