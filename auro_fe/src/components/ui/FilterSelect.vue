<template>
    <select
        :value="modelValue"
        class="bg-background text-foreground text-sm rounded px-2 py-1 border border-border focus:outline-none focus:border-primary/30"
        @change="$emit('update:modelValue', ($event.target as HTMLSelectElement).value)"
    >
        <option value="">{{ placeholder }}</option>
        <option v-for="option in options" :key="option.value" :value="option.value">
            {{ option.label }}
        </option>
    </select>
</template>

<script setup lang="ts">
withDefaults(
    defineProps<{
        modelValue: string;
        options: Array<{ value: string; label: string }>;
        placeholder?: string;
    }>(),
    {
        placeholder: "Select",
    },
);

defineEmits<{
    (e: "update:modelValue", value: string): void;
}>();
</script>
