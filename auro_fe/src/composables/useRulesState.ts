import { onMounted, onUnmounted, ref } from "vue";
import { opusApi } from "@/services/api";

export type RuleFrameInput = {
    frame: string | null;
    regime: string | null;
    adx: number | null;
};

export type RuleStateRow = {
    live_strategy_id: string;
    instrument: string;
    granularity: string;
    strategy_type: string;
    rules_enabled: boolean;
    reason: string;
    computed_at: string | null;
    composite_regime: string | null;
    frames: RuleFrameInput[];
};

export type RulesStateResponse = {
    computed_at: string | null;
    summary: {
        trading: number;
        live: number;
        curator_enabled: boolean;
    };
    strategies: RuleStateRow[];
};

const POLL_INTERVAL_MS = 30_000;

export function useRulesState() {
    const loading = ref(true);
    const error = ref<string | null>(null);
    const computedAt = ref<string | null>(null);
    const summary = ref({ trading: 0, live: 0, curator_enabled: false });
    const strategies = ref<RuleStateRow[]>([]);

    let refreshTimer: ReturnType<typeof setInterval> | null = null;

    async function load() {
        try {
            const payload = await opusApi.get<RulesStateResponse>("/rules/state");
            computedAt.value = payload.computed_at;
            summary.value = payload.summary;
            strategies.value = payload.strategies ?? [];
            error.value = null;
        } catch (err) {
            console.error("Failed to load rules state", err);
            error.value = "Unable to load rules state";
        } finally {
            loading.value = false;
        }
    }

    onMounted(() => {
        load();
        refreshTimer = setInterval(load, POLL_INTERVAL_MS);
    });

    onUnmounted(() => {
        if (refreshTimer) clearInterval(refreshTimer);
    });

    return {
        loading,
        error,
        computedAt,
        summary,
        strategies,
        load,
    };
}
