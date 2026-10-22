<template>
    <div class="min-h-screen bg-background">
        <AppHeader />
        <router-view />
    </div>
</template>

<script setup lang="ts">
import AppHeader from "@/components/AppHeader.vue";
</script>
