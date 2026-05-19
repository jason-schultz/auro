import { onBeforeUnmount, onMounted, ref } from "vue";

interface RustHealth {
    last_tick_seconds_ago: number | null;
    last_evaluator_run_seconds_ago: number | null;
    last_candle_persisted_seconds_ago: number | null;
    open_positions_count: number;
    instrument_metadata_loaded: boolean;
    account_snapshot_age_seconds: number | null;
}

interface OpusHealth {
    uptime_seconds: number;
    reconciler_last_run_seconds_ago: number | null;
    regime_detector_last_poll_seconds_ago: number | null;
    rules_engine_last_push_seconds_ago: number | null;
}

interface SystemHealth {
    nav: number;
    pnl_today: number;
    pnl_today_pct: number;
    rust: RustHealth;
    opus: OpusHealth;
}

export type PulseState = "green" | "yellow" | "red" | "closed";

function inferPulse(value: number | null, threshold: number): PulseState {
    if (value == null) return "red";
    if (value < threshold) return "green";
    if (value < threshold * 2) return "yellow";
    return "red";
}

function isForexClosed(now: Date): boolean {
    const day = now.getUTCDay();
    const hour = now.getUTCHours();
    if (day === 6) return true;
    if (day === 0 && hour < 21) return true;
    return false;
}

export function useSystemPulse() {
    const loading = ref(false);
    const error = ref<string | null>(null);
    const data = ref<SystemHealth | null>(null);
    const fetchedAt = ref<Date | null>(null);

    let timer: ReturnType<typeof setInterval> | null = null;

    async function load() {
        loading.value = true;
        error.value = null;
        try {
            const response = await fetch("/opus/health/system");
            const body = (await response.json()) as SystemHealth | { error: string };
            if (!response.ok || !("rust" in body)) {
                throw new Error("error" in body ? body.error : "Failed to load system pulse");
            }
            data.value = body;
            fetchedAt.value = new Date();
        } catch (e) {
            error.value = e instanceof Error ? e.message : "Failed to load system pulse";
            data.value = null;
        } finally {
            loading.value = false;
        }
    }

    function rustState(): PulseState {
        if (!data.value) return "red";
        if (isForexClosed(new Date())) return "closed";
        return inferPulse(data.value.rust.last_tick_seconds_ago, 60);
    }

    function opusState(): PulseState {
        return data.value ? inferPulse(data.value.opus.reconciler_last_run_seconds_ago, 90) : "red";
    }

    function regimeState(): PulseState {
        return data.value ? inferPulse(data.value.opus.regime_detector_last_poll_seconds_ago, 360) : "red";
    }

    function rulesState(): PulseState {
        return data.value ? inferPulse(data.value.opus.rules_engine_last_push_seconds_ago, 360) : "red";
    }

    onMounted(() => {
        void load();
        timer = setInterval(() => {
            void load();
        }, 15_000);
    });

    onBeforeUnmount(() => {
        if (timer) clearInterval(timer);
    });

    return {
        loading,
        error,
        data,
        fetchedAt,
        load,
        rustState,
        opusState,
        regimeState,
        rulesState,
    };
}
