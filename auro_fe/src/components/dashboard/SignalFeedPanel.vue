<template>
    <div class="fr-card p-4">
        <div class="flex items-center justify-between mb-4">
            <div class="fr-section-label mb-0 pb-0 border-b-0">Signal Feed</div>
            <span class="text-[10px] font-mono px-2 py-1 rounded" :class="statusClass">
                {{ stateLabel }}
            </span>
        </div>

        <StateMessage
            v-if="error"
            :compact="true"
            :message="error"
        />

        <StateMessage
            v-else-if="events.length === 0"
            :compact="true"
            message="Waiting for live signal events..."
        />

        <div v-else class="space-y-2 max-h-72 overflow-auto pr-1">
            <div
                v-for="event in events"
                :key="event.timestamp + event.strategy_id + event.action"
                class="rounded-md border border-border bg-background/70 px-3 py-2"
            >
                <div class="flex items-center justify-between gap-2 mb-1">
                    <div class="flex items-center gap-2 flex-wrap">
                        <span class="font-mono text-sm text-foreground">
                            {{ event.instrument.replace("_", "/") }}
                        </span>
                        <span class="text-[10px] px-1.5 py-0.5 rounded bg-primary/10 text-primary/80 font-mono">
                            {{ event.granularity }}
                        </span>
                        <span class="text-[10px] px-1.5 py-0.5 rounded font-mono" :class="actionClass(event.action)">
                            {{ event.action }}
                        </span>
                    </div>
                    <span class="text-[10px] text-muted-foreground font-mono">
                        {{ timeAgo(event.timestamp) }}
                    </span>
                </div>

                <div class="flex items-center gap-2 text-xs font-mono mb-1">
                    <span class="text-foreground">${{ formatPrice(event.price, event.instrument) }}</span>
                    <span class="text-muted-foreground">{{ event.strategy_type }}</span>
                    <span
                        v-if="event.oanda_trade_id"
                        class="text-muted-foreground"
                    >
                        #{{ event.oanda_trade_id }}
                    </span>
                </div>

                <div class="text-xs text-muted-foreground" :title="event.reason">
                    {{ event.reason }}
                </div>
            </div>
        </div>
    </div>
</template>

<script setup lang="ts">
import { computed } from "vue";
import StateMessage from "@/components/ui/StateMessage.vue";
import { useSignalFeed } from "@/composables/useSignalFeed";

const { events, state, error } = useSignalFeed();

const stateLabel = computed(() => {
    if (state.value === "connected") return "LIVE";
    if (state.value === "connecting") return "CONNECTING";
    return "OFFLINE";
});

const statusClass = computed(() => {
    if (state.value === "connected") return "bg-emerald-500/15 text-emerald-300";
    if (state.value === "connecting") return "bg-amber-500/15 text-amber-300";
    return "bg-red-500/15 text-red-300";
});

function actionClass(action: string): string {
    if (action.includes("opened")) return "bg-emerald-500/15 text-emerald-300";
    if (action.includes("closed")) return "bg-blue-500/15 text-blue-300";
    if (action.includes("rejected")) return "bg-red-500/15 text-red-300";
    return "bg-muted text-muted-foreground";
}

function formatPrice(price: number, instrument: string): string {
    return price.toFixed(instrument.includes("JPY") ? 3 : 5);
}

function timeAgo(ts: string): string {
    const eventAt = new Date(ts).getTime();
    const now = Date.now();
    const seconds = Math.max(0, Math.floor((now - eventAt) / 1000));

    if (seconds < 60) return `${seconds}s ago`;
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes}m ago`;
    const hours = Math.floor(minutes / 60);
    return `${hours}h ago`;
}
</script>
