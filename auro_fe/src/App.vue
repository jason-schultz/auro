<template>
    <div class="min-h-screen bg-background">
        <AppHeader />
        <router-view />
    </div>
</template>

<script setup lang="ts">
import { onMounted } from "vue";
import { useWebSocket } from "@/composables/useWebSocket";
import AppHeader from "@/components/AppHeader.vue";

const wsUrl = `ws://${window.location.host}/ws/prices`;
const { connect } = useWebSocket(wsUrl);

onMounted(() => {
    connect();
});
</script>
