import { mount } from "@vue/test-utils";
import { describe, expect, it } from "vitest";
import StatValueCard from "@/components/ui/StatValueCard.vue";

describe("StatValueCard", () => {
    it("renders label and value", () => {
        const wrapper = mount(StatValueCard, {
            props: {
                label: "Unrealized P&L",
                value: "$123.45",
            },
        });

        expect(wrapper.text()).toContain("Unrealized P&L");
        expect(wrapper.text()).toContain("$123.45");
    });

    it("applies custom value class", () => {
        const wrapper = mount(StatValueCard, {
            props: {
                label: "Realized P&L",
                value: "$-50.00",
                valueClass: "text-red-400",
            },
        });

        const valueNode = wrapper.find(".text-sm.font-mono.font-medium");
        expect(valueNode.classes()).toContain("text-red-400");
    });
});
