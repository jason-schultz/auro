import { ref, onMounted } from "vue";
import { api } from "@/services/api";

export type BrokerKind = "oanda" | "questrade" | "wealthsimple";

export interface BrokerAccount {
    id: string;
    name: string;
    account_type: string;
    currency: string;
    cash: number | null;
    market_value: number | null;
    total_equity: number | null;
    buying_power: number | null;
}

export interface BrokerStatus {
    broker: BrokerKind;
    display_name: string;
    connected: boolean;
    error?: string;
    accounts: BrokerAccount[];
}

export function useBrokers() {
    const brokers = ref<BrokerStatus[]>([]);
    const loading = ref(false);
    const error = ref<string | null>(null);

    async function refresh() {
        loading.value = true;
        error.value = null;
        try {
            brokers.value = await api.get<BrokerStatus[]>("/brokers");
        } catch (e) {
            error.value = e instanceof Error ? e.message : "Failed to load brokers";
        } finally {
            loading.value = false;
        }
    }

    onMounted(refresh);

    return { brokers, loading, error, refresh };
}
