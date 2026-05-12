import type { StrategyParameters } from "@/types/strategy";

export interface PipelineEvaluation {
    stage: string;
    status: string;
    stats: Record<string, number> | null;
    failure_reason: string | null;
}

export interface PipelineConfig {
    config_id: string;
    instrument: string;
    granularity: string;
    strategy_type: string;
    parameters: StrategyParameters;
    source: string;
    depth: number;
    parent_config_id: string | null;
    evo_generation?: number | null;
    lineage_id?: string | null;
    score?: number | null;
    inserted_at?: string;
    stage: string | null;
    status: string | null;
    stats: Record<string, number> | null;
    failure_reason: string | null;
    evaluations: PipelineEvaluation[];
}

export interface PipelineSummary {
    total: number;
    running: number;
    passed: number;
    failed: number;
    pending: number;
    backtest: number;
    walk_forward: number;
    monte_carlo: number;
}

export interface PipelineStatusResponse {
    configs: PipelineConfig[];
    summary: PipelineSummary | null;
}
