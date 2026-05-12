<template>
    <span :class="classes">{{ label }}</span>
</template>

<script setup lang="ts">
import { computed } from "vue";
import { badgePillClasses } from "@/lib/ui";

const props = withDefaults(
    defineProps<{
        label: string;
        size?: "xs" | "2xs";
        rounded?: "default" | "full";
        extraClass?: string;
    }>(),
    {
        size: "xs",
        rounded: "default",
        extraClass: "",
    },
);

const classes = computed(() => {
    return badgePillClasses({
        size: props.size,
        rounded: props.rounded,
        extraClass: props.extraClass,
    });
});
</script>
