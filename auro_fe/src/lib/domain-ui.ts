export function statusBadgeClass(status: string | null | undefined): string {
    switch (status) {
        case "valid":
        case "passed":
            return "bg-emerald-500/10 text-emerald-400";
        case "verify":
        case "running":
            return "bg-primary/10 text-primary";
        case "failed":
            return "bg-red-500/10 text-red-400";
        default:
            return "bg-muted text-muted-foreground";
    }
}

export function strategyTypeBadgeClass(strategyType: string): string {
    switch (strategyType) {
        case "mean_reversion":
            return "bg-blue-500/10 text-blue-400";
        case "donchian":
            return "bg-amber-500/10 text-amber-400";
        case "macd":
            return "bg-teal-500/10 text-teal-400";
        default:
            return "bg-violet-500/10 text-violet-400";
    }
}

export function strategyTypeBadgeLabel(strategyType: string): string {
    switch (strategyType) {
        case "mean_reversion":
            return "Mean Rev";
        case "donchian":
            return "Donchian";
        case "macd":
            return "MACD";
        case "trend_following":
            return "Trend";
        default:
            return strategyType;
    }
}

export function tradeExitReasonBadgeClass(exitReason: string): string {
    if (exitReason === "TakeProfit") {
        return "bg-emerald-500/10 text-emerald-400";
    }

    if (exitReason === "StopLoss") {
        return "bg-red-500/10 text-red-400";
    }

    return "bg-muted text-muted-foreground";
}

export function tradeDirectionBadgeClass(
    status: string,
    direction: string,
): string {
    if (status === "closed") {
        return "bg-muted text-muted-foreground";
    }

    return direction === "Long"
        ? "bg-emerald-500/10 text-emerald-400"
        : "bg-red-500/10 text-red-400";
}

export function strategyEnabledBadgeClass(enabled: boolean | null): string {
    return enabled
        ? "bg-emerald-500/10 text-emerald-400"
        : "bg-muted text-muted-foreground";
}

export function pnlClass(value: number | null | undefined): string {
    if (value == null) return "text-muted-foreground";
    return value >= 0 ? "text-green-400" : "text-red-400";
}

export function slStateClass(state: string | null | undefined): string {
    if (state === "Trailing") return "text-green-400";
    if (state === "Breakeven") return "text-blue-400";
    return "text-muted-foreground";
}

export function formatIndicatorValue(value: unknown): string {
    if (value == null) return "—";
    if (typeof value === "number") return value.toFixed(5);
    return String(value);
}
