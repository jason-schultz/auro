<template>
    <main class="p-6 max-w-3xl">
        <ViewHeader :title="isEditing ? 'Edit Strategy' : 'New Strategy'" />

        <DataCard
            :loading="false"
            :empty="false"
            card-class="p-6"
            content-class=""
        >
            <StateMessage message="Strategy editor - coming next session." :compact="true" />
        </DataCard>
    </main>
</template>

<script setup lang="ts">
import { computed } from "vue";
import { useRoute } from "vue-router";
import DataCard from "@/components/ui/DataCard.vue";
import StateMessage from "@/components/ui/StateMessage.vue";
import ViewHeader from "@/components/ui/ViewHeader.vue";

const route = useRoute();
const isEditing = computed(() => !!route.params.id);
</script>
