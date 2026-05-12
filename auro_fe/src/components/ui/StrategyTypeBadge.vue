<template>
    <BadgePill
        :label="strategyTypeBadgeLabel(type)"
        :extra-class="strategyTypeBadgeClass(type)"
    />
</template>

<script setup lang="ts">
import BadgePill from "@/components/ui/BadgePill.vue";
import {
    strategyTypeBadgeClass,
    strategyTypeBadgeLabel,
} from "@/lib/domain-ui";

defineProps<{
    type: string;
}>();
</script>
