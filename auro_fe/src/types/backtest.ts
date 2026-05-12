import type { PipelineConfig } from "@/types/pipeline";
import type { StrategyParameters } from "@/types/strategy";

export interface BacktestRun {
    id: string;
    strategy_name: string;
    strategy_type: string;
    instrument: string;
    granularity: string;
    parameters: StrategyParameters;
    total_return: number;
    win_rate: number;
    sharpe_ratio: number;
    max_drawdown: number;
    num_trades: number;
    avg_win: number;
    avg_loss: number;
    status: string;
    reason_flagged: string | null;
    execution_duration_ms: number;
    _pipeline?: PipelineConfig;
}

export interface BacktestTrade {
    id: string;
    entry_price: number;
    exit_price: number;
    entry_time: string;
    exit_time: string;
    pnl_percent: number;
    entry_reason: string;
    exit_reason: string;
}

export interface BacktestResultsResponse {
    results: BacktestRun[];
}

export interface BacktestTradesResponse {
    trades: BacktestTrade[];
}
