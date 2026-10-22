import { ref } from "vue";

import { getApiErrorMessage, opusApi } from "../services/api";

/**
 * Instrument-agnostic editor state — the draft's `definition`. The strategy
 * is signal logic (components + wiring + risk); instrument/granularity are a
 * preview context remembered only as last-used defaults.
 */
export interface DraftDefinition {
    version: number;
    components: Array<{ name: string; type: string; params: Record<string, number | string> }>;
    longEnabled: boolean;
    shortEnabled: boolean;
    entryLong: unknown;
    entryShort: unknown;
    exitLong: unknown;
    exitShort: unknown;
    stop: { type: string; params: Record<string, number | string> };
    sizingPct: number;
    maxHoldBars: number | null;
    maxNotionalPct?: number | null;
}

export interface StrategyDraft {
    id: string;
    name: string;
    definition: DraftDefinition;
    last_instrument: string | null;
    last_granularity: string | null;
    updated_at: string;
}

export function useStrategyDrafts() {
    const drafts = ref<StrategyDraft[]>([]);
    const loading = ref(false);
    const error = ref<string | null>(null);

    async function refresh() {
        loading.value = true;
        try {
            const body = await opusApi.get<{ drafts: StrategyDraft[] }>("/strategy-drafts");
            drafts.value = body.drafts;
            error.value = null;
        } catch (e) {
            error.value = getApiErrorMessage(e, "Failed to load drafts");
        } finally {
            loading.value = false;
        }
    }

    async function create(
        name: string,
        definition: DraftDefinition,
        lastInstrument: string,
        lastGranularity: string,
    ): Promise<StrategyDraft> {
        const draft = await opusApi.post<StrategyDraft>("/strategy-drafts", {
            name,
            definition,
            last_instrument: lastInstrument,
            last_granularity: lastGranularity,
        });
        await refresh();
        return draft;
    }

    async function update(
        id: string,
        name: string,
        definition: DraftDefinition,
        lastInstrument: string,
        lastGranularity: string,
    ): Promise<StrategyDraft> {
        const draft = await opusApi.put<StrategyDraft>(`/strategy-drafts/${id}`, {
            name,
            definition,
            last_instrument: lastInstrument,
            last_granularity: lastGranularity,
        });
        await refresh();
        return draft;
    }

    async function remove(id: string) {
        await opusApi.delete(`/strategy-drafts/${id}`);
        await refresh();
    }

    return { drafts, loading, error, refresh, create, update, remove };
}
