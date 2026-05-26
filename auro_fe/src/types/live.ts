import type { StrategyParameters } from "@/types/strategy";

export interface AccountData {
    id: string;
    currency: string;
    balance: string;
    unrealized_pl: string;
    pl: string;
    open_trade_count: number;
    open_position_count: number;
    margin_used: string;
    margin_available: string;
}

export interface StopDisplay {
    priceLabel: string;
    distanceLabel: string;
    distanceClass: string;
}

export interface TargetDisplay {
    price: string;
    distanceLabel: string;
    distanceClass: string;
}

export interface Position {
    id: string;
    instrument: string;
    side: string;
    units: string;
    entry: string;
    current: string;
    pl: number;
    stopLossState: string;
    stopDisplay: StopDisplay | null;
    targetDisplay: TargetDisplay | null;
}

export interface AlgoEntry {
    id: string;
    instrument: string;
    direction: string;
    units: string;
    action: string;
    entryReason: string;
    exitReason: string;
    entryPrice: number | null;
    exitPrice: number | null;
    duration: string | null;
    status: string;
    time: string;
    pnl: number | null;
    strategyLabel: string | null;
}

export interface OpenTradeOrder {
    price?: string;
    distance?: string;
}

export interface OpenTrade {
    id: string;
    instrument: string;
    price: string;
    currentUnits?: string;
    initialUnits?: string;
    unrealizedPL?: string;
    stopLossOrder?: OpenTradeOrder;
    takeProfitOrder?: OpenTradeOrder;
    trailingStopLossOrder?: OpenTradeOrder;
}

export interface OpenTradesResponse {
    trades: OpenTrade[];
}

export interface LiveTradeRecord {
    id: string;
    instrument: string;
    direction: string;
    units: string;
    status: string;
    entry_time: string;
    exit_time: string | null;
    entry_price: string | number | null;
    exit_price: string | number | null;
    pnl_percent: number | null;
    entry_reason: string | null;
    exit_reason: string | null;
    strategy_type?: string | null;
    strategy_parameters?: StrategyParameters | null;
    strategy_granularity?: string | null;
}

export interface LiveTradesResponse {
    trades: LiveTradeRecord[];
}

export interface BacktestStats {
    total_return: number;
    win_rate: number;
    sharpe_ratio: number;
    max_drawdown: number;
    num_trades: number;
    avg_win: number;
    avg_loss: number;
}

export interface LiveStats {
    num_trades: number;
    wins: number;
    losses: number;
    win_rate: number;
    total_return: number;
    avg_win: number;
    avg_loss: number;
}

export interface OosStats {
    oos_sharpe: number;
    oos_num_trades: number;
    oos_return: number;
    sharpe_retention: number;
}

export interface CurrentSuspension {
    trigger_kind: string;
    trigger_detail: string;
    triggered_at: string;
}

export interface KFoldStats {
    fold_count: number;
    pass_count: number;
    pass_rate: number;
    median_sharpe: number;
}

export interface LiveStrategy {
    id: string;
    strategy_type: string;
    instrument: string;
    granularity: string;
    parameters: StrategyParameters;
    enabled: boolean;
    max_position_size: string;
    created_at: string;
    updated_at: string;
    backtest_run_id: string | null;
    source: "grid_search" | "pipeline" | string;
    pipeline_score: number | null;
    backtest_stats: BacktestStats | null;
    oos_stats: OosStats | null;
    live_stats: LiveStats | null;
    kfold_stats: KFoldStats | null;
    current_suspension?: CurrentSuspension | null;
}

export interface LiveStrategiesResponse {
    strategies: LiveStrategy[];
    count: number;
}
