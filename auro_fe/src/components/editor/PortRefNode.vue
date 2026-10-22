<template>
    <div class="space-y-1.5">
        <div class="flex items-center gap-1.5">
            <select
                :class="INPUT_CLASS" class="w-[70px]"
                :value="kind"
                @change="changeKind(($event.target as HTMLSelectElement).value)"
            >
                <option value="port">port</option>
                <option value="and">AND</option>
                <option value="or">OR</option>
                <option value="not">NOT</option>
            </select>

            <select
                v-if="kind === 'port'"
                :class="INPUT_CLASS" class="flex-1 font-mono"
                :value="modelValue as string"
                @change="emit('update:modelValue', ($event.target as HTMLSelectElement).value)"
            >
                <option v-if="ports.length === 0" value="" disabled>add a component first</option>
                <option v-for="port in ports" :key="port" :value="port">{{ port }}</option>
            </select>

            <button
                v-if="removable"
                type="button"
                class="text-[10px] text-muted-foreground hover:text-red-400 px-1"
                title="Remove condition"
                @click="emit('remove')"
            >
                ✕
            </button>
        </div>

        <!-- AND / OR children -->
        <div
            v-if="kind === 'and' || kind === 'or'"
            class="ml-4 pl-2 border-l border-border/60 space-y-1.5"
        >
            <PortRefNode
                v-for="(child, idx) in children"
                :key="idx"
                :model-value="child"
                :ports="ports"
                :removable="children.length > 1"
                @update:model-value="updateChild(idx, $event)"
                @remove="removeChild(idx)"
            />
            <button
                type="button"
                class="text-[10px] text-primary/70 hover:text-primary"
                @click="addChild"
            >
                + condition
            </button>
        </div>

        <!-- NOT child -->
        <div v-if="kind === 'not'" class="ml-4 pl-2 border-l border-border/60">
            <PortRefNode
                :model-value="notChild"
                :ports="ports"
                :removable="false"
                @update:model-value="emit('update:modelValue', { not: $event })"
            />
        </div>
    </div>
</template>

<script setup lang="ts">
import { computed } from "vue";

import type { PortRef } from "@/lib/strategyCatalog";
import { INPUT_CLASS } from "@/lib/ui";

const props = withDefaults(
    defineProps<{
        modelValue: PortRef;
        ports: string[];
        removable?: boolean;
    }>(),
    { removable: false },
);

const emit = defineEmits<{
    (e: "update:modelValue", value: PortRef): void;
    (e: "remove"): void;
}>();

const kind = computed<"port" | "and" | "or" | "not">(() => {
    if (typeof props.modelValue === "string") return "port";
    if ("and" in props.modelValue) return "and";
    if ("or" in props.modelValue) return "or";
    return "not";
});

const children = computed<PortRef[]>(() => {
    if (typeof props.modelValue === "string") return [];
    if ("and" in props.modelValue) return props.modelValue.and;
    if ("or" in props.modelValue) return props.modelValue.or;
    return [];
});

const notChild = computed<PortRef>(() => {
    if (typeof props.modelValue !== "string" && "not" in props.modelValue) {
        return props.modelValue.not;
    }
    return defaultPort();
});

function defaultPort(): string {
    return props.ports[0] ?? "";
}

function firstLeaf(): PortRef {
    // Preserve the current node as the first child when wrapping in a group.
    return props.modelValue;
}

function changeKind(next: string) {
    if (next === kind.value) return;
    switch (next) {
        case "port":
            emit("update:modelValue", typeof props.modelValue === "string" ? props.modelValue : defaultPort());
            break;
        case "and":
            emit("update:modelValue", { and: [firstLeaf(), defaultPort()] });
            break;
        case "or":
            emit("update:modelValue", { or: [firstLeaf(), defaultPort()] });
            break;
        case "not":
            emit("update:modelValue", { not: firstLeaf() });
            break;
    }
}

function updateChild(idx: number, value: PortRef) {
    const next = [...children.value];
    next[idx] = value;
    emit("update:modelValue", kind.value === "and" ? { and: next } : { or: next });
}

function removeChild(idx: number) {
    const next = children.value.filter((_, i) => i !== idx);
    if (next.length === 1) {
        // Collapse a single-child group back to its child.
        emit("update:modelValue", next[0]);
    } else {
        emit("update:modelValue", kind.value === "and" ? { and: next } : { or: next });
    }
}

function addChild() {
    emit(
        "update:modelValue",
        kind.value === "and"
            ? { and: [...children.value, defaultPort()] }
            : { or: [...children.value, defaultPort()] },
    );
}
</script>
