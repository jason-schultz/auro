import type { StrategyParameters } from "../types/strategy";

export function strategyTypeLabel(type: string): string {
    if (type === "trend_following") return "Trend";
    if (type === "mean_reversion") return "Mean Rev";
    return type;
}

export function formatStrategyConfigLabel(
    strategyType: string | null | undefined,
    params: StrategyParameters | null | undefined,
    granularity: string | null | undefined,
): string | null {
    if (!strategyType) return null;
    const gran = granularity ? ` ${granularity}` : "";

    if (strategyType === "trend_following" && params) {
        const fast = params.fast_period;
        const slow = params.slow_period;
        if (fast != null && slow != null) {
            return `TF F${fast}/S${slow}${gran}`;
        }
        return `TF${gran}`;
    }

    if (strategyType === "mean_reversion" && params) {
        const ma = params.ma_period;
        const entry = params.entry_threshold;
        if (ma != null && entry != null) {
            const entryPct = (entry * 100).toFixed(1);
            return `MR MA${ma} ${entryPct}%${gran}`;
        }
        return `MR${gran}`;
    }

    return `${strategyType}${gran}`;
}
