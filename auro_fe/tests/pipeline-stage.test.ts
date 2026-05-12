import { describe, expect, it } from "bun:test";
import { buildPipelineStageViewModels } from "../src/lib/pipeline-stage";

describe("pipeline stage helpers", () => {
    it("builds stage rows with formatted metrics", () => {
        const rows = buildPipelineStageViewModels([
            {
                stage: "backtest",
                status: "passed",
                stats: {
                    sharpe: 1.23456,
                    total_return: 0.1234,
                    num_trades: 42,
                },
                failure_reason: null,
            },
            {
                stage: "walk_forward",
                status: "passed",
                stats: {
                    is_sharpe: 1.1,
                    oos_sharpe: 0.7,
                    sharpe_retention: 0.83,
                },
                failure_reason: null,
            },
            {
                stage: "monte_carlo",
                status: "failed",
                stats: null,
                failure_reason: "insufficient robustness",
            },
        ]);

        expect(rows[0]?.status).toBe("passed");
        expect(rows[0]?.metrics.map((m) => `${m.label}:${m.value}`)).toEqual([
            "Sharpe:1.235",
            "Return:12.34%",
            "Trades:42",
        ]);

        expect(rows[1]?.metrics.map((m) => `${m.label}:${m.value}`)).toEqual([
            "IS:1.100",
            "OOS:0.700",
            "Retention:0.83",
        ]);

        expect(rows[2]?.status).toBe("failed");
        expect(rows[2]?.metrics).toHaveLength(0);
        expect(rows[2]?.failureReason).toBe("insufficient robustness");
    });

    it("fills pending stages when evaluations are missing", () => {
        const rows = buildPipelineStageViewModels([]);
        expect(rows.map((r) => r.status)).toEqual(["pending", "pending", "pending"]);
    });
});
