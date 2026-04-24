<template>
    <main class="p-6 max-w-3xl">
        <h2 class="text-lg font-semibold text-foreground mb-6">
            {{ isEditing ? "Edit Strategy" : "New Strategy" }}
        </h2>

        <div class="fr-card p-6 text-muted-foreground">
            Strategy editor — coming next session.
        </div>
    </main>
</template>

<script setup lang="ts">
import { computed } from "vue";
import { useRoute } from "vue-router";

const route = useRoute();
const isEditing = computed(() => !!route.params.id);
</script>
