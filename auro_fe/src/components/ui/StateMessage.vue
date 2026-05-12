<template>
    <div :class="wrapperClass">
        <div>{{ message }}</div>
        <div v-if="detail" class="text-[10px] text-muted-foreground/70 mt-1">
            {{ detail }}
        </div>
    </div>
</template>

<script setup lang="ts">
import { computed } from "vue";
import { stateMessageClasses } from "@/lib/ui";

const props = withDefaults(
    defineProps<{
        message: string;
        detail?: string;
        fullHeight?: boolean;
        compact?: boolean;
    }>(),
    {
        fullHeight: false,
        compact: false,
    },
);

const wrapperClass = computed(() => {
    return stateMessageClasses({
        fullHeight: props.fullHeight,
        compact: props.compact,
    });
});
</script>
