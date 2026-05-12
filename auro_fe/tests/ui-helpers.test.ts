import { describe, expect, it } from "bun:test";
import { badgePillClasses, stateMessageClasses } from "../src/lib/ui";

describe("ui helpers", () => {
    it("builds badge classes for default size and rounded", () => {
        const classes = badgePillClasses({
            size: "xs",
            rounded: "default",
            extraClass: "bg-muted text-muted-foreground",
        });

        expect(classes).toContain("inline-flex items-center font-medium");
        expect(classes).toContain("text-[10px] px-1.5 py-0.5");
        expect(classes).toContain("rounded");
        expect(classes).toContain("bg-muted text-muted-foreground");
    });

    it("builds badge classes for compact variant", () => {
        const classes = badgePillClasses({
            size: "2xs",
            rounded: "full",
        });

        expect(classes).toContain("text-[9px] px-1 py-0.5");
        expect(classes).toContain("rounded-full");
    });

    it("builds full-height state message classes", () => {
        const classes = stateMessageClasses({
            fullHeight: true,
            compact: false,
        });

        expect(classes).toContain("flex-1 flex items-center justify-center");
        expect(classes).toContain("py-8");
        expect(classes).toContain("text-sm text-muted-foreground");
    });

    it("builds compact state message classes", () => {
        const classes = stateMessageClasses({
            fullHeight: false,
            compact: true,
        });

        expect(classes).toContain("text-center");
        expect(classes).toContain("py-4");
    });
});
