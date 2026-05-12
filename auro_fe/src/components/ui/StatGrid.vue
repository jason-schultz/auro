<template>
    <div :class="columnsClass">
        <StatValueCard
            v-for="item in items"
            :key="item.label"
            :label="item.label"
            :value="item.value"
            :value-class="item.valueClass"
            :meta="item.meta"
            :meta-class="item.metaClass"
        />
    </div>
</template>

<script setup lang="ts">
import StatValueCard from "@/components/ui/StatValueCard.vue";
import type { StatGridItem } from "@/lib/ui";

withDefaults(
    defineProps<{
        items: StatGridItem[];
        columnsClass?: string;
    }>(),
    {
        columnsClass: "grid grid-cols-2 md:grid-cols-4 gap-3",
    },
);
</script>
