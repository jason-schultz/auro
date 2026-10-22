import { onBeforeUnmount, onMounted, ref } from "vue";

import { getApiErrorMessage, opusApi } from "../services/api";

export interface StrategyPerformanceRow {
    strategy_id: string;
    instrument: string;
    granularity: string;
    strategy_type: string;
    enabled: boolean;
    trades: number;
    win_rate_pct: number;
    pnl_cad: number;
    avg_pnl_pct: number;
    open_trades: number;
}

interface StrategyPerformanceResponse {
    rows: StrategyPerformanceRow[];
    from: string;
    to: string;
}

const REFRESH_MS = 60_000;

export function useStrategyPerformance() {
    const loading = ref(true);
    const error = ref<string | null>(null);
    const rows = ref<StrategyPerformanceRow[]>([]);

    let timer: ReturnType<typeof setInterval> | null = null;

    async function load() {
        try {
            const body = await opusApi.get<StrategyPerformanceResponse>(
                "/journal/strategy-performance",
            );
            rows.value = body.rows;
            error.value = null;
        } catch (e) {
            error.value = getApiErrorMessage(e, "Failed to load strategy performance");
        } finally {
            loading.value = false;
        }
    }

    onMounted(() => {
        void load();
        timer = setInterval(() => {
            void load();
        }, REFRESH_MS);
    });

    onBeforeUnmount(() => {
        if (timer) clearInterval(timer);
    });

    return {
        loading,
        error,
        rows,
        load,
    };
}
