import { describe, expect, it } from "bun:test";
import {
    dataTableHeadClass,
    filterToolbarClass,
    filterToolbarDividerClass,
    resolveDataPanelState,
    viewHeaderClass,
} from "../src/lib/view";

describe("view ui helpers", () => {
    it("prioritizes loading state", () => {
        expect(resolveDataPanelState(true, true)).toBe("loading");
        expect(resolveDataPanelState(true, false)).toBe("loading");
    });

    it("returns empty when not loading and empty", () => {
        expect(resolveDataPanelState(false, true)).toBe("empty");
    });

    it("returns ready when not loading and not empty", () => {
        expect(resolveDataPanelState(false, false)).toBe("ready");
    });

    it("builds compact and default header classes", () => {
        expect(viewHeaderClass(true)).toContain("mb-3");
        expect(viewHeaderClass(false)).toContain("mb-4");
        expect(viewHeaderClass(false)).toContain("flex items-center justify-between");
    });

    it("builds toolbar classes for inline and block variants", () => {
        expect(filterToolbarClass(false, false)).toContain("gap-3 mb-3");
        expect(filterToolbarClass(true, true)).toContain("gap-2 mb-0");
    });

    it("keeps divider class stable", () => {
        expect(filterToolbarDividerClass()).toBe("w-px h-4 bg-border");
    });

    it("builds table head classes for sticky and static variants", () => {
        expect(dataTableHeadClass(true)).toBe("sticky top-0 bg-card");
        expect(dataTableHeadClass(false)).toBe("bg-card");
    });
});
