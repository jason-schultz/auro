import { formatPercent } from "./format";
import type { PipelineEvaluation } from "../types/pipeline";

export type PipelineStageKey = "backtest" | "walk_forward" | "monte_carlo";

export interface PipelineStageMetric {
    label: string;
    value: string;
}

export interface PipelineStageViewModel {
    key: PipelineStageKey;
    label: string;
    status: string;
    metrics: PipelineStageMetric[];
    failureReason: string | null;
}

export const PIPELINE_STAGE_KEYS: PipelineStageKey[] = [
    "backtest",
    "walk_forward",
    "monte_carlo",
];

export function buildPipelineStageViewModels(
    evaluations: PipelineEvaluation[],
): PipelineStageViewModel[] {
    return PIPELINE_STAGE_KEYS.map((stage) => {
        const evaluation = evaluations.find((e) => e.stage === stage);
        const stats = evaluation?.stats;

        return {
            key: stage,
            label: stage.replace("_", " "),
            status: evaluation?.status ?? "pending",
            metrics: buildStageMetrics(stage, stats),
            failureReason: evaluation?.failure_reason ?? null,
        };
    });
}

function buildStageMetrics(
    stage: PipelineStageKey,
    stats: Record<string, number> | null | undefined,
): PipelineStageMetric[] {
    if (!stats) return [];

    if (stage === "backtest") {
        return [
            { label: "Sharpe", value: fixed(stats.sharpe, 3) },
            { label: "Return", value: formatPercent(stats.total_return) },
            { label: "Trades", value: raw(stats.num_trades) },
        ];
    }

    if (stage === "walk_forward") {
        return [
            { label: "IS", value: fixed(stats.is_sharpe, 3) },
            { label: "OOS", value: fixed(stats.oos_sharpe, 3) },
            { label: "Retention", value: fixed(stats.sharpe_retention, 2) },
        ];
    }

    return [
        { label: "Median", value: fixed(stats.median_sharpe, 3) },
        { label: "Profitable", value: formatPercent(stats.profitable_pct) },
        { label: "P95 DD", value: formatPercent(stats.p95_drawdown) },
    ];
}

function fixed(value: number | undefined, decimals: number): string {
    if (value == null) return "-";
    return value.toFixed(decimals);
}

function raw(value: number | undefined): string {
    if (value == null) return "-";
    return String(value);
}
