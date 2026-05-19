type StrategyParams = Record<string, unknown> | null | undefined;

function parseNumber(input: unknown): number {
    return typeof input === "number" ? input : Number(input);
}

function fromReason(reason: string, pattern: RegExp): number {
    return Number(reason.match(pattern)?.[1]);
}

export function buildStrategyPrimerText(
    strategyType: string,
    strategyParameters: StrategyParams,
): string {
    if (strategyType === "trend_following") {
        const fastPeriod = parseNumber(strategyParameters?.fast_period);
        const slowPeriod = parseNumber(strategyParameters?.slow_period);
        const fastLabel = Number.isFinite(fastPeriod) ? fastPeriod : "fast";
        const slowLabel = Number.isFinite(slowPeriod) ? slowPeriod : "slow";

        return `This strategy follows momentum using two moving averages: fast (${fastLabel}) reacts to recent candles, while slow (${slowLabel}) tracks the bigger trend.`;
    }

    if (strategyType === "mean_reversion") {
        const maPeriod = parseNumber(strategyParameters?.ma_period);
        const maLabel = Number.isFinite(maPeriod) ? maPeriod : 20;

        return `This strategy looks for "stretch then snap back" moves: if price drifts far from its ${maLabel}-candle average, it expects a return toward that average.`;
    }

    return "This strategy enters and exits based on predefined signal rules.";
}

export function buildEntryNarrativeText(input: {
    strategyType: string;
    strategyParameters: StrategyParams;
    entryReason: string | null | undefined;
}): string {
    const reason = input.entryReason ?? "";

    if (input.strategyType === "mean_reversion") {
        const maPeriod =
            parseNumber(input.strategyParameters?.ma_period) ||
            fromReason(reason, /MA(\d+)/) ||
            20;
        const maValue = fromReason(reason, /MA\d+=([0-9.]+)/);
        const deviationPct = fromReason(reason, /deviation=([-0-9.]+)%/);
        const thresholdPct = parseNumber(input.strategyParameters?.entry_threshold) * 100;

        const maValueText = Number.isFinite(maValue) ? maValue.toFixed(5) : "unknown";
        const devText = Number.isFinite(deviationPct)
            ? `${Math.abs(deviationPct).toFixed(2)}% below`
            : "below";
        const thresholdText = Number.isFinite(thresholdPct)
            ? `${Math.abs(thresholdPct).toFixed(2)}% below`
            : "the threshold";

        return `Entry signal: price looked cheaper than usual versus its recent baseline. The ${maPeriod}-candle moving average was ${maValueText}; price was ${devText} that baseline, which passed the entry rule (${thresholdText}).`;
    }

    if (input.strategyType === "trend_following") {
        const crossAbove = reason.includes("CrossAbove");
        const fastMa = fromReason(reason, /fast_ma=([0-9.]+)/);
        const slowMa = fromReason(reason, /slow_ma=([0-9.]+)/);
        const fastPeriod = parseNumber(input.strategyParameters?.fast_period);
        const slowPeriod = parseNumber(input.strategyParameters?.slow_period);

        const directionText = crossAbove ? "up" : "down";
        const fastText = Number.isFinite(fastMa) ? fastMa.toFixed(5) : "unknown";
        const slowText = Number.isFinite(slowMa) ? slowMa.toFixed(5) : "unknown";
        const fastLabel = Number.isFinite(fastPeriod) ? fastPeriod : "fast";
        const slowLabel = Number.isFinite(slowPeriod) ? slowPeriod : "slow";
        const maGap = Number.isFinite(fastMa) && Number.isFinite(slowMa) ? fastMa - slowMa : NaN;
        const maGapPct = Number.isFinite(maGap) && Number.isFinite(slowMa) && slowMa !== 0
            ? (maGap / slowMa) * 100
            : NaN;
        const gapText = Number.isFinite(maGapPct) ? `${Math.abs(maGapPct).toFixed(2)}%` : "a small";
        const momentumText = crossAbove
            ? "recent prices are climbing faster than the longer-term trend"
            : "recent prices are falling faster than the longer-term trend";

        return `Entry signal: fast (${fastLabel}) crossed ${directionText} and moved ${crossAbove ? "above" : "below"} slow (${slowLabel}) (${fastText} vs ${slowText}). That means ${momentumText}, by about ${gapText}.`;
    }

    return "Entry signal: the strategy's entry conditions were met on that candle.";
}

export function buildExitNarrativeText(input: {
    exitReason: string | null | undefined;
    stopLossStateAtClose: string | null | undefined;
    entryPrice: number | null | undefined;
    exitPrice: number | null | undefined;
    strategyParameters: StrategyParams;
}): string {
    const reason = input.exitReason ?? "Unknown";

    if (reason.includes("StopLoss")) {
        const stopLossPct = parseNumber(input.strategyParameters?.stop_loss) * 100;
        const stopText = Number.isFinite(stopLossPct)
            ? `${Math.abs(stopLossPct).toFixed(2)}% safety limit`
            : "safety limit";
        return `Exit signal: StopLoss hit after price moved against us and reached the ${stopText}.`;
    }

    if (reason.includes("TakeProfit")) {
        return "Exit signal: TakeProfit hit, so gains were locked at the planned target.";
    }

    if (reason.includes("TrailingStop")) {
        const slState = input.stopLossStateAtClose ?? "trailing";
        return `Exit signal: TrailingStop hit. The stop had ratcheted with price (${slState}), then pullback touched it.`;
    }

    if (reason.includes("TrendReversal")) {
        return "Exit signal: trend-reversal condition fired, so the system closed before waiting for a hard stop.";
    }

    if (input.entryPrice != null && input.exitPrice != null) {
        const movedPct = ((input.exitPrice - input.entryPrice) / input.entryPrice) * 100;
        return `Exit signal: close rule triggered after price moved ${movedPct.toFixed(2)}% from entry.`;
    }

    return "Exit signal: one of the strategy close rules triggered.";
}
