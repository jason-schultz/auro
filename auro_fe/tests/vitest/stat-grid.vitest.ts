import { mount } from "@vue/test-utils";
import { describe, expect, it } from "vitest";
import StatGrid from "@/components/ui/StatGrid.vue";

describe("StatGrid", () => {
    it("renders multiple stat cards with values and meta", () => {
        const wrapper = mount(StatGrid, {
            props: {
                items: [
                    {
                        label: "Entry",
                        value: "$1.10000",
                        meta: "May 11, 10:30",
                    },
                    {
                        label: "P&L",
                        value: "+1.20%",
                        valueClass: "text-emerald-400",
                    },
                ],
            },
        });

        expect(wrapper.text()).toContain("Entry");
        expect(wrapper.text()).toContain("$1.10000");
        expect(wrapper.text()).toContain("May 11, 10:30");
        expect(wrapper.text()).toContain("P&L");
        expect(wrapper.text()).toContain("+1.20%");
    });
});
