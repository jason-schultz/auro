<template>
    <section>
        <div v-if="loading" class="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <div v-for="n in 2" :key="n" class="h-72 bg-muted/20 rounded-lg animate-pulse" />
        </div>

        <div v-else-if="positions.length === 0" class="fr-card p-8 text-center text-sm text-muted-foreground">
            No open positions
        </div>

        <div v-else class="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <OpenPositionCard
                v-for="position in positions"
                :key="position.id"
                :position="position"
            />
        </div>
    </section>
</template>

<script setup lang="ts">
import OpenPositionCard from "@/components/dashboard/OpenPositionCard.vue";
import { useOpenPositions } from "@/composables/useOpenPositions";

const { loading, positions } = useOpenPositions();
</script>
