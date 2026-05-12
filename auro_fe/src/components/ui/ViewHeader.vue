<template>
    <div :class="headerClass">
        <h2 class="text-lg font-semibold text-foreground">{{ title }}</h2>
        <slot name="actions" />
    </div>
</template>

<script setup lang="ts">
import { computed } from "vue";
import { viewHeaderClass } from "@/lib/view";

const props = withDefaults(
    defineProps<{
        title: string;
        compact?: boolean;
    }>(),
    {
        compact: false,
    },
);

const headerClass = computed(() => viewHeaderClass(props.compact));
</script>
