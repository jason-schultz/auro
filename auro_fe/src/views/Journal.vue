<template>
    <main class="p-6">
        <ViewHeader title="Trade Journal" />

        <DataCard
            :loading="false"
            :empty="false"
            card-class="p-12"
            content-class=""
        >
            <StateMessage message="Wealthsimple manual trade tracking - Phase 3." />
        </DataCard>
    </main>
</template>

<script setup lang="ts">
import DataCard from "@/components/ui/DataCard.vue";
import StateMessage from "@/components/ui/StateMessage.vue";
import ViewHeader from "@/components/ui/ViewHeader.vue";
</script>
