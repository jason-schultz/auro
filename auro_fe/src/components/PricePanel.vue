<template>
    <div class="space-y-3">
        <div class="flex items-center justify-between">
            <div class="fr-section-label mb-0 pb-0 border-b-0">Live Prices</div>
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
            v-if="instruments.length === 0"
            class="text-sm text-muted-foreground py-8 text-center"
        >
            Waiting for price data...
        </div>

        <div v-else class="grid gap-2">
            <div
                v-for="item in instruments"
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
                        {{ formatInstrument(item.instrument) }}
                    </span>
                    <span class="text-[10px] text-[#3a3a4a] font-mono">
                        {{ formatTime(item.time) }}
                    </span>
                </div>

                <div class="grid grid-cols-3 gap-2 text-xs">
                    <div>
                        <div class="text-muted-foreground mb-0.5">Bid</div>
                        <div
                            class="font-mono font-medium transition-colors duration-300"
                            :class="{
                                'text-emerald-400': item.bidDirection === 'up',
                                'text-red-400': item.bidDirection === 'down',
                                'text-foreground': item.bidDirection === 'flat',
                            }"
                        >
                            {{ item.bid }}
                        </div>
                    </div>

                    <div>
                        <div class="text-muted-foreground mb-0.5">Ask</div>
                        <div
                            class="font-mono font-medium transition-colors duration-300"
                            :class="{
                                'text-emerald-400': item.askDirection === 'up',
                                'text-red-400': item.askDirection === 'down',
                                'text-foreground': item.askDirection === 'flat',
                            }"
                        >
                            {{ item.ask }}
                        </div>
                    </div>

                    <div>
                        <div class="text-muted-foreground mb-0.5">Spread</div>
                        <div class="font-mono font-medium text-[#4a4a5a]">
                            {{ item.spread }}
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>
</template>

<script setup lang="ts">
import { computed } from "vue";
import { useMarketStore } from "@/stores/market";

const marketStore = useMarketStore();

const connected = computed(() => marketStore.connected);
const instruments = computed(() => marketStore.instrumentList);

function formatInstrument(instrument: string): string {
    return instrument.replace("_", "/");
}

function formatTime(time: string): string {
    try {
        const date = new Date(time);
        return date.toLocaleTimeString();
    } catch {
        return time;
    }
}
</script>
