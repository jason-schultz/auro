import { ref } from "vue";

import { getApiErrorMessage, opusApi } from "../services/api";

interface BreakdownEntry {
    pnl_cad: number;
    trades: number;
    win_rate_pct: number;
}

export interface JournalKpis {
    trade_count: number;
    win_count: number;
    loss_count: number;
    breakeven_count: number;
    win_rate_pct: number;
    total_pnl_cad: number;
    avg_win_cad: number;
    avg_loss_cad: number;
    profit_factor: number | null;
    expectancy_cad: number;
    avg_mfe_pct: number;
    avg_mae_pct: number;
    by_instrument: Array<BreakdownEntry & { instrument: string }>;
    by_strategy_type: Array<BreakdownEntry & { strategy_type: string }>;
    by_regime_at_entry: Array<BreakdownEntry & { regime: string }>;
}

export function useJournalKpis() {
    const loading = ref(false);
    const error = ref<string | null>(null);
    const kpis = ref<JournalKpis | null>(null);

    async function load() {
        loading.value = true;
        error.value = null;

        try {
            kpis.value = await opusApi.get<JournalKpis>("/journal/kpis");
        } catch (e) {
            error.value = getApiErrorMessage(e, "Failed to load KPIs");
            kpis.value = null;
        } finally {
            loading.value = false;
        }
    }

    return {
        loading,
        error,
        kpis,
        load,
    };
}
