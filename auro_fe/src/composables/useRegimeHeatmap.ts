import { onBeforeUnmount, onMounted, ref } from "vue";

export type RegimeState = "trending" | "choppy" | "uncertain" | "unknown";

export interface RegimeHeatmapCell {
    granularity: string;
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
            const response = await fetch("/opus/regimes/heatmap");
            const body = (await response.json()) as RegimeHeatmapResponse | { error: string };

            if (!response.ok || !("rows" in body)) {
                throw new Error("error" in body ? body.error : "Failed to load regime heatmap");
            }

            rows.value = body.rows;
            granularities.value = body.granularities;
        } catch (e) {
            error.value = e instanceof Error ? e.message : "Failed to load regime heatmap";
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
