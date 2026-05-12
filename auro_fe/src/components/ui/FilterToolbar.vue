<template>
    <div :class="toolbarClass">
        <slot />
    </div>
</template>

<script setup lang="ts">
import { computed } from "vue";
import { filterToolbarClass } from "@/lib/view";

const props = withDefaults(
    defineProps<{
        inline?: boolean;
        tight?: boolean;
    }>(),
    {
        inline: false,
        tight: false,
    },
);

const toolbarClass = computed(() => filterToolbarClass(props.inline, props.tight));
</script>
