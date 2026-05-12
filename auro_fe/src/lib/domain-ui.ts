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
    return strategyType === "mean_reversion"
        ? "bg-blue-500/10 text-blue-400"
        : "bg-violet-500/10 text-violet-400";
}

export function strategyTypeBadgeLabel(strategyType: string): string {
    return strategyType === "mean_reversion" ? "Mean Rev" : "Trend";
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
