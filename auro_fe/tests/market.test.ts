import { describe, expect, it } from "bun:test";
import { defaultDeployUnits, getInstrumentCategory } from "../src/lib/market";

describe("market helpers", () => {
    it("returns expected categories", () => {
        expect(getInstrumentCategory("EUR_USD")).toBe("forex");
        expect(getInstrumentCategory("XAU_USD")).toBe("metals");
        expect(getInstrumentCategory("WTICO_USD")).toBe("commodities");
        expect(getInstrumentCategory("NAS100_USD")).toBe("indices");
        expect(getInstrumentCategory("USB10Y_USD")).toBe("bonds");
    });

    it("falls back to forex for unknown instruments", () => {
        expect(getInstrumentCategory("UNKNOWN_ASSET")).toBe("forex");
    });

    it("returns expected deploy units", () => {
        expect(defaultDeployUnits("XAU_USD")).toBe("1");
        expect(defaultDeployUnits("XAG_USD")).toBe("10");
        expect(defaultDeployUnits("WTICO_USD")).toBe("10");
        expect(defaultDeployUnits("NATGAS_USD")).toBe("100");
        expect(defaultDeployUnits("SPX500_USD")).toBe("1");
        expect(defaultDeployUnits("USB10Y_USD")).toBe("1");
        expect(defaultDeployUnits("EUR_USD")).toBe("1000");
    });
});
