<template>
    <BadgePill
        :label="displayLabel"
        rounded="full"
        :extra-class="statusBadgeClass(status)"
    />
</template>

<script setup lang="ts">
import { computed } from "vue";
import BadgePill from "@/components/ui/BadgePill.vue";
import { statusBadgeClass } from "@/lib/domain-ui";

const props = defineProps<{
    status: string | null | undefined;
    label?: string;
}>();

const displayLabel = computed(() => props.label ?? props.status ?? "pending");
</script>
