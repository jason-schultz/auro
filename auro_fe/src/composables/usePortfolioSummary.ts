import { onBeforeUnmount, onMounted, ref } from "vue";

import { getApiErrorMessage, opusApi } from "../services/api";

export interface PortfolioAccount {
    broker: string;
    label: string;
    currency: string;
    value: number;
    balance?: number;
    unrealized_pl?: number;
    cash?: number | null;
    market_value?: number;
    open_positions: number;
    as_of: string;
}

interface PortfolioSummaryResponse {
    total_cad: number;
    as_of: string;
    accounts: PortfolioAccount[];
}

const REFRESH_MS = 60_000;

export function usePortfolioSummary() {
    const loading = ref(true);
    const error = ref<string | null>(null);
    const totalCad = ref(0);
    const accounts = ref<PortfolioAccount[]>([]);

    let timer: ReturnType<typeof setInterval> | null = null;

    async function load() {
        try {
            const body = await opusApi.get<PortfolioSummaryResponse>("/portfolio/summary");
            totalCad.value = body.total_cad;
            accounts.value = body.accounts;
            error.value = null;
        } catch (e) {
            error.value = getApiErrorMessage(e, "Failed to load portfolio summary");
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
        totalCad,
        accounts,
        load,
    };
}
