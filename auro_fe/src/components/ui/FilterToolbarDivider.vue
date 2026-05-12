<template>
    <div :class="dividerClass" />
</template>

<script setup lang="ts">
import { filterToolbarDividerClass } from "@/lib/view";

const dividerClass = filterToolbarDividerClass();
</script>
