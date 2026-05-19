import { computed, ref, watch } from "vue";

export type EquityResolution = "1m" | "5m" | "15m" | "1h" | "1d";

export interface EquityCurvePoint {
    timestamp: string;
    nav: number;
    balance: number;
    unrealized_pl: number;
    margin_used: number;
}

interface EquityCurveResponse {
    points: EquityCurvePoint[];
    from: string;
    to: string;
    resolution: EquityResolution;
}

const cache = new Map<string, EquityCurveResponse>();

function toFiniteNumber(value: unknown): number | null {
    if (typeof value === "number" && Number.isFinite(value)) return value;
    if (typeof value === "string") {
        const parsed = Number(value);
        return Number.isFinite(parsed) ? parsed : null;
    }
    return null;
}

function normalizePoints(rawPoints: unknown): EquityCurvePoint[] {
    if (!Array.isArray(rawPoints)) return [];

    return rawPoints
        .map((point) => {
            if (!point || typeof point !== "object") return null;
            const p = point as Record<string, unknown>;

            const timestamp = typeof p.timestamp === "string" ? p.timestamp : "";
            if (!timestamp || Number.isNaN(new Date(timestamp).getTime())) return null;

            const nav = toFiniteNumber(p.nav);
            const balance = toFiniteNumber(p.balance);
            const unrealizedPl = toFiniteNumber(p.unrealized_pl);
            const marginUsed = toFiniteNumber(p.margin_used);

            if (nav == null || balance == null || unrealizedPl == null || marginUsed == null) {
                return null;
            }

            return {
                timestamp,
                nav,
                balance,
                unrealized_pl: unrealizedPl,
                margin_used: marginUsed,
            };
        })
        .filter((point): point is EquityCurvePoint => point !== null);
}

function toIso(ts: Date): string {
    return ts.toISOString();
}

function rangeToFrom(range: "1D" | "1W" | "1M" | "3M" | "ALL"): Date | null {
    const now = new Date();

    switch (range) {
        case "1D":
            return new Date(now.getTime() - 24 * 60 * 60 * 1000);
        case "1W":
            return new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);
        case "1M": {
            const d = new Date(now);
            d.setMonth(now.getMonth() - 1);
            return d;
        }
        case "3M": {
            const d = new Date(now);
            d.setMonth(now.getMonth() - 3);
            return d;
        }
        case "ALL":
            return null;
    }
}

function resolutionForRange(range: "1D" | "1W" | "1M" | "3M" | "ALL"): EquityResolution {
    switch (range) {
        case "1D":
            return "5m";
        case "1W":
            return "15m";
        case "1M":
            return "1h";
        case "3M":
            return "1h";
        case "ALL":
            return "1d";
    }
}

export function useEquityCurve() {
    const range = ref<"1D" | "1W" | "1M" | "3M" | "ALL">("1M");
    const loading = ref(false);
    const error = ref<string | null>(null);
    const points = ref<EquityCurvePoint[]>([]);

    async function fetchCurve(
        from: Date | null,
        to: Date,
        resolution: EquityResolution,
    ): Promise<EquityCurvePoint[]> {
        const params = new URLSearchParams();
        params.set("to", toIso(to));
        params.set("resolution", resolution);
        if (from) {
            params.set("from", toIso(from));
        }

        const key = params.toString();
        const cached = cache.get(key);
        if (cached) {
            return cached.points;
        }

        const response = await fetch(`/opus/account/equity-curve?${key}`);
        const body = (await response.json()) as EquityCurveResponse | { error: string };

        if (!response.ok || !("points" in body)) {
            throw new Error("error" in body ? body.error : "Failed to load equity curve");
        }

        const normalized = normalizePoints(body.points);
        cache.set(key, { ...body, points: normalized });
        return normalized;
    }

    async function load() {
        const to = new Date();
        const from = rangeToFrom(range.value);
        const resolution = resolutionForRange(range.value);

        loading.value = true;
        error.value = null;

        try {
            let resolvedPoints = await fetchCurve(from, to, resolution);

            // When data is sparse, coarse buckets can collapse into a single point.
            // Fall back to minute resolution so the curve remains visible.
            if (resolvedPoints.length <= 1 && resolution !== "1m") {
                resolvedPoints = await fetchCurve(from, to, "1m");
            }

            points.value = resolvedPoints;
        } catch (e) {
            error.value = e instanceof Error ? e.message : "Failed to load equity curve";
            points.value = [];
        } finally {
            loading.value = false;
        }
    }

    const summary = computed(() => {
        if (points.value.length < 1) {
            return {
                nav: 0,
                delta: 0,
                deltaPct: 0,
            };
        }

        const first = points.value[0].nav;
        const last = points.value[points.value.length - 1].nav;
        const delta = last - first;

        return {
            nav: last,
            delta,
            deltaPct: first > 0 ? (delta / first) * 100 : 0,
        };
    });

    watch(range, () => {
        void load();
    });

    return {
        range,
        points,
        summary,
        loading,
        error,
        load,
    };
}
