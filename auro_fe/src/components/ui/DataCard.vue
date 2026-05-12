<template>
    <div class="fr-card flex-1 overflow-hidden flex flex-col" :class="cardClass">
        <StateMessage
            v-if="panelState === 'loading'"
            :message="loadingMessage"
            :full-height="true"
        />
        <StateMessage
            v-else-if="panelState === 'empty'"
            :message="emptyMessage"
            :full-height="true"
        />
        <div v-else :class="contentClass">
            <slot />
        </div>
    </div>
</template>

<script setup lang="ts">
import { computed } from "vue";
import { resolveDataPanelState } from "@/lib/view";
import StateMessage from "@/components/ui/StateMessage.vue";

const props = withDefaults(
    defineProps<{
        loading: boolean;
        empty: boolean;
        loadingMessage?: string;
        emptyMessage?: string;
        cardClass?: string;
        contentClass?: string;
    }>(),
    {
        loadingMessage: "Loading...",
        emptyMessage: "No data found.",
        cardClass: "",
        contentClass: "overflow-auto flex-1",
    },
);

const panelState = computed(() => resolveDataPanelState(props.loading, props.empty));
</script>
