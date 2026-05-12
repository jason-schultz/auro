<template>
    <main class="p-6 h-[calc(100vh-57px)] flex flex-col">
        <ViewHeader title="Markets" />

        <FilterToolbar>
            <SegmentedFilterGroup
                :model-value="activeTab"
                :options="tabs"
                active-class="bg-primary/10 text-primary"
                inactive-class="text-muted-foreground hover:text-foreground"
                @update:model-value="(value) => (activeTab = value)"
            />
        </FilterToolbar>

        <div v-if="marketClosed" class="fr-card p-3 mb-4">
            <StateMessage
                message="Forex market is currently closed. Live prices will resume Sunday 5pm ET."
                :compact="true"
            />
        </div>

        <!-- TSX placeholder -->
        <div v-if="activeTab === 'tsx'" class="flex-1">
            <div class="fr-card p-12">
                <StateMessage
                    message="TSX equities - Wealthsimple manual tracking"
                    detail="Data source TBD. Will pull from Yahoo Finance or Alpha Vantage."
                />
            </div>
        </div>

        <!-- OANDA markets -->
        <div
            v-else
            class="grid grid-cols-1 lg:grid-cols-4 gap-4 flex-1 min-h-0"
        >
            <aside class="lg:col-span-1 overflow-y-auto">
                <div class="flex items-center justify-between mb-3">
                    <div class="fr-section-label mb-0 pb-0 border-b-0">
                        {{ currentTabLabel }}
                    </div>
                    <div class="flex items-center gap-2">
                        <span
                            class="h-1.5 w-1.5 rounded-full"
                            :class="
                                connected
                                    ? 'bg-emerald-500 animate-pulse'
                                    : 'bg-red-500'
                            "
                        />
                        <span class="text-[10px] text-muted-foreground">
                            {{ connected ? "Connected" : "Disconnected" }}
                        </span>
                    </div>
                </div>

                <div
                    v-if="filteredInstruments.length === 0"
                >
                    <StateMessage
                        :message="loading ? 'Loading instruments...' : 'No instruments available'"
                    />
                </div>

                <div v-else class="grid gap-2">
                    <div
                        v-for="item in filteredInstruments"
                        :key="item.instrument"
                        class="fr-card-interactive p-3 cursor-pointer"
                        :class="
                            marketStore.selectedInstrument === item.instrument
                                ? 'fr-card-selected'
                                : ''
                        "
                        @click="marketStore.selectInstrument(item.instrument)"
                    >
                        <div class="flex items-center justify-between mb-2">
                            <span class="text-sm font-semibold text-foreground">
                                {{ item.instrument.replace("_", "/") }}
                            </span>
                            <span
                                v-if="item.time"
                                class="text-[10px] text-muted-foreground/50 font-mono"
                            >
                                {{ formatTime(item.time) }}
                            </span>
                        </div>

                        <div
                            v-if="item.bid"
                            class="grid grid-cols-3 gap-2 text-xs"
                        >
                            <div>
                                <div class="text-muted-foreground mb-0.5">
                                    Bid
                                </div>
                                <div
                                    class="font-mono font-medium transition-colors duration-300"
                                    :class="{
                                        'text-emerald-400':
                                            item.bidDirection === 'up',
                                        'text-red-400':
                                            item.bidDirection === 'down',
                                        'text-foreground':
                                            item.bidDirection === 'flat',
                                    }"
                                >
                                    {{ item.bid }}
                                </div>
                            </div>
                            <div>
                                <div class="text-muted-foreground mb-0.5">
                                    Ask
                                </div>
                                <div
                                    class="font-mono font-medium transition-colors duration-300"
                                    :class="{
                                        'text-emerald-400':
                                            item.askDirection === 'up',
                                        'text-red-400':
                                            item.askDirection === 'down',
                                        'text-foreground':
                                            item.askDirection === 'flat',
                                    }"
                                >
                                    {{ item.ask }}
                                </div>
                            </div>
                            <div>
                                <div class="text-muted-foreground mb-0.5">
                                    Spread
                                </div>
                                <div
                                    class="font-mono font-medium text-muted-foreground"
                                >
                                    {{ item.spread }}
                                </div>
                            </div>
                        </div>

                        <div v-else class="text-xs text-muted-foreground">
                            Waiting for data...
                        </div>
                    </div>
                </div>
            </aside>

            <div class="lg:col-span-3 fr-card overflow-hidden">
                <CandleChart />
            </div>
        </div>
    </main>
</template>

<script setup lang="ts">
import { useMarkets } from "@/composables/useMarkets";
import CandleChart from "@/components/CandleChart.vue";
import FilterToolbar from "@/components/ui/FilterToolbar.vue";
import SegmentedFilterGroup from "@/components/ui/SegmentedFilterGroup.vue";
import StateMessage from "@/components/ui/StateMessage.vue";
import ViewHeader from "@/components/ui/ViewHeader.vue";

const {
    marketStore,
    connected,
    activeTab,
    loading,
    tabs,
    currentTabLabel,
    marketClosed,
    filteredInstruments,
    formatTime,
} = useMarkets();
</script>
