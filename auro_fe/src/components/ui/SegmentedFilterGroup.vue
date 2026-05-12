<template>
    <div class="flex gap-1">
        <button
            v-for="option in options"
            :key="option.id"
            class="px-2.5 py-1 text-sm rounded transition-colors"
            :class="modelValue === option.id ? activeClass : inactiveClass"
            @click="$emit('update:modelValue', option.id)"
        >
            {{ option.label }}
            <span
                v-if="counts && (counts[option.id] ?? 0) > 0"
                class="ml-0.5 text-[10px] font-mono opacity-60"
            >
                {{ counts[option.id] }}
            </span>
        </button>
    </div>
</template>

<script setup lang="ts">
defineProps<{
    modelValue: string;
    options: Array<{ id: string; label: string }>;
    counts?: Record<string, number>;
    activeClass?: string;
    inactiveClass?: string;
}>();

defineEmits<{
    (e: "update:modelValue", value: string): void;
}>();
</script>
