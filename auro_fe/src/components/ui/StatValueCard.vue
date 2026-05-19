<template>
    <div class="bg-background rounded-md p-3">
        <div class="text-[10px] text-muted-foreground mb-1">
            <MetricLabel :label="label" :explainer="explainer" />
        </div>
        <div class="text-sm font-mono font-medium" :class="valueClass">
            {{ value }}
        </div>
        <div
            v-if="meta"
            class="text-[10px] font-mono mt-0.5"
            :class="metaClass"
        >
            {{ meta }}
        </div>
    </div>
</template>

<script setup lang="ts">
import MetricLabel from "@/components/ui/MetricLabel.vue";

withDefaults(
    defineProps<{
        label: string;
        value: string;
        explainer?: string;
        valueClass?: string;
        meta?: string;
        metaClass?: string;
    }>(),
    {
        valueClass: "text-foreground",
        metaClass: "text-muted-foreground/60",
    },
);
</script>
