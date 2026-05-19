<template>
    <span class="inline-flex items-center gap-1">
        <span>{{ label }}</span>
        <span
            v-if="explainer"
            class="inline-flex h-3.5 w-3.5 items-center justify-center rounded-full border border-border text-[9px] font-semibold text-muted-foreground cursor-help"
            :title="explainer"
            aria-label="Metric explainer"
        >
            ?
        </span>
    </span>
</template>

<script setup lang="ts">
defineProps<{
    label: string;
    explainer?: string;
}>();
</script>
