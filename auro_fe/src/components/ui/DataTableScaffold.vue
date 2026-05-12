<template>
    <DataCard
        :loading="loading"
        :empty="empty"
        :loading-message="loadingMessage"
        :empty-message="emptyMessage"
        :card-class="cardClass"
        :content-class="contentClass"
    >
        <table :class="tableClass">
            <thead :class="headClass">
                <tr :class="headRowClass">
                    <slot name="head" />
                </tr>
            </thead>
            <tbody :class="bodyClass">
                <slot name="body" />
            </tbody>
        </table>
    </DataCard>
</template>

<script setup lang="ts">
import DataCard from "@/components/ui/DataCard.vue";

withDefaults(
    defineProps<{
        loading: boolean;
        empty: boolean;
        loadingMessage?: string;
        emptyMessage?: string;
        cardClass?: string;
        contentClass?: string;
        tableClass?: string;
        headClass?: string;
        headRowClass?: string;
        bodyClass?: string;
    }>(),
    {
        loadingMessage: "Loading...",
        emptyMessage: "No data found.",
        cardClass: "",
        contentClass: "overflow-auto flex-1",
        tableClass: "w-full text-sm",
        headClass: "sticky top-0 bg-card",
        headRowClass: "",
        bodyClass: "",
    },
);
</script>
