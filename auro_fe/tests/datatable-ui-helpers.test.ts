import { describe, expect, it } from "bun:test";
import {
    BACKTEST_COLUMN_SETS,
    PIPELINE_COLUMNS,
    STRATEGIES_COLUMNS,
    ariaSortForColumn,
    stickyFirstColumnClass,
    tableCellAlignClass,
    tableHeaderAlignClass,
    tableWidthClass,
} from "../src/lib/ui";

describe("datatable ui helpers", () => {
    it("maps aria-sort correctly for sortable and active columns", () => {
        expect(
            ariaSortForColumn({
                sortable: true,
                columnKey: "sharpe",
                sortKey: "sharpe",
                sortDir: "asc",
            }),
        ).toBe("ascending");

        expect(
            ariaSortForColumn({
                sortable: true,
                columnKey: "sharpe",
                sortKey: "sharpe",
                sortDir: "desc",
            }),
        ).toBe("descending");

        expect(
            ariaSortForColumn({
                sortable: true,
                columnKey: "instrument",
                sortKey: "sharpe",
                sortDir: "asc",
            }),
        ).toBe("none");

        expect(
            ariaSortForColumn({
                sortable: false,
                columnKey: "params",
                sortKey: "params",
                sortDir: "asc",
            }),
        ).toBe("none");
    });

    it("returns stable alignment classes for status, enabled, and metric keys", () => {
        expect(tableHeaderAlignClass("status")).toBe("text-center");
        expect(tableCellAlignClass("enabled")).toBe("text-center");
        expect(tableHeaderAlignClass("sharpe_ratio")).toBe("text-right");
        expect(tableCellAlignClass("score")).toContain("tabular-nums");
        expect(tableHeaderAlignClass("instrument")).toBe("text-left");
    });

    it("returns width tokens with fallback", () => {
        expect(tableWidthClass("backtests", "instrument")).toContain("w-[8.5rem]");
        expect(tableWidthClass("pipeline", "failure_reason")).toContain("w-[13rem]");
        expect(tableWidthClass("strategies", "enabled")).toContain("w-[4rem]");
        expect(tableWidthClass("backtests", "unknown_key")).toContain("w-[7rem]");
    });

    it("builds sticky first-column variants for header and body", () => {
        expect(
            stickyFirstColumnClass({
                isFirst: true,
                isHeader: true,
            }),
        ).toContain("top-0");

        expect(
            stickyFirstColumnClass({
                isFirst: true,
                isHeader: false,
                selected: true,
            }),
        ).toContain("bg-primary/5");

        expect(
            stickyFirstColumnClass({
                isFirst: false,
                isHeader: false,
            }),
        ).toBe("");
    });

    it("keeps shared column contracts non-empty", () => {
        expect(BACKTEST_COLUMN_SETS.default.length).toBeGreaterThan(0);
        expect(PIPELINE_COLUMNS.length).toBeGreaterThan(0);
        expect(STRATEGIES_COLUMNS.length).toBeGreaterThan(0);
    });
});
