import { onBeforeUnmount, onMounted, ref } from "vue";

import { getApiErrorMessage, opusApi } from "../services/api";

export type RegimeState = "trending" | "choppy" | "uncertain" | "unknown";

export interface RegimeHeatmapCell {
    granularity: string;
    applicable: boolean;
    regime: RegimeState;
    adx: number | null;
    bandwidth_pct: number | null;
    last_close_time: string | null;
}

export interface RegimeHeatmapRow {
    instrument: string;
    cells: RegimeHeatmapCell[];
}

interface RegimeHeatmapResponse {
    instruments: string[];
    granularities: string[];
    rows: RegimeHeatmapRow[];
    count: number;
}

export function useRegimeHeatmap() {
    const loading = ref(false);
    const error = ref<string | null>(null);
    const rows = ref<RegimeHeatmapRow[]>([]);
    const granularities = ref<string[]>([]);

    let timer: ReturnType<typeof setInterval> | null = null;

    async function load() {
        loading.value = true;
        error.value = null;

        try {
            const body = await opusApi.get<RegimeHeatmapResponse>("/regimes/heatmap");
            rows.value = body.rows;
            granularities.value = body.granularities;
        } catch (e) {
            error.value = getApiErrorMessage(e, "Failed to load regime heatmap");
            rows.value = [];
            granularities.value = [];
        } finally {
            loading.value = false;
        }
    }

    onMounted(() => {
        void load();
        timer = setInterval(() => {
            void load();
        }, 30_000);
    });

    onBeforeUnmount(() => {
        if (timer) clearInterval(timer);
    });

    return {
        loading,
        error,
        rows,
        granularities,
        load,
    };
}
